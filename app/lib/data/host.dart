import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// A paired bridge: where to reach it and the device token it issued.
class HostConfig {
  HostConfig({required this.name, required this.urls, required this.token, required this.deviceId, required this.deviceName});

  final String name;

  /// WebSocket URLs to try in order (Tailscale IP, MagicDNS name, …).
  final List<String> urls;
  final String token;
  final String deviceId;
  final String deviceName;

  Map<String, Object?> toJson() => {'name': name, 'urls': urls, 'token': token, 'deviceId': deviceId, 'deviceName': deviceName};

  factory HostConfig.fromJson(Map<String, dynamic> j) => HostConfig(
        name: j['name'] as String? ?? 'bridge',
        urls: (j['urls'] as List? ?? const []).cast<String>(),
        token: j['token'] as String,
        deviceId: j['deviceId'] as String? ?? '',
        deviceName: j['deviceName'] as String? ?? '',
      );

  HostConfig withUrls(List<String> urls) => HostConfig(name: name, urls: urls, token: token, deviceId: deviceId, deviceName: deviceName);

  /// Pairing again issues a new device ID, so match computers by their endpoints.
  bool sameComputer(HostConfig other) {
    final origins = urls.map((url) => httpBase(url).origin).toSet();
    return other.urls.any((url) => origins.contains(httpBase(url).origin));
  }

  /// `ws://host:port/acp` → `http://host:port`.
  static Uri httpBase(String wsUrl) {
    final u = Uri.parse(wsUrl);
    return Uri(scheme: u.scheme == 'wss' || u.scheme == 'https' ? 'https' : 'http', host: u.host, port: u.hasPort ? u.port : null);
  }

  Uri httpUri(String wsUrl, String path, [Map<String, String>? query]) => httpBase(wsUrl).replace(path: path, queryParameters: query);
}

/// Accept browser URLs as well as the native app's ws/wss URLs.
String bridgeWebSocketUrl(String input, {bool secure = false}) {
  final text = input.trim();
  final uri = Uri.tryParse(text.contains('://') ? text : '${secure ? 'wss' : 'ws'}://$text');
  if (uri == null || !const ['http', 'https', 'ws', 'wss'].contains(uri.scheme) || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
    throw PairingException('請輸入有效的 bridge 網址（http、https、ws 或 wss）');
  }
  return Uri(scheme: uri.scheme == 'https' || uri.scheme == 'wss' ? 'wss' : 'ws', host: uri.host, port: uri.hasPort ? uri.port : null, path: '/acp').toString();
}

/// All saved pairings and the computer selected for the next app launch.
class HostLibrary {
  HostLibrary({List<HostConfig> hosts = const [], this.activeIndex = 0})
    : hosts = List.unmodifiable(hosts);

  final List<HostConfig> hosts;
  final int activeIndex;

  HostConfig? get activeHost => hosts.isEmpty
      ? null
      : hosts[activeIndex >= 0 && activeIndex < hosts.length ? activeIndex : 0];

  Map<String, Object?> toJson() => {
    'hosts': hosts.map((host) => host.toJson()).toList(),
    'activeIndex': activeIndex,
  };

  factory HostLibrary.fromJson(Map<String, dynamic> json) {
    // Keep existing single-computer pairings when upgrading the app.
    if (!json.containsKey('hosts')) {
      return HostLibrary(hosts: [HostConfig.fromJson(json)]);
    }
    return HostLibrary(
      hosts: (json['hosts'] as List)
          .map((host) => HostConfig.fromJson(host as Map<String, dynamic>))
          .toList(),
      activeIndex: json['activeIndex'] as int? ?? 0,
    );
  }
}

class HostStore {
  Future<String?> loadAppearance() => _storage.read(key: 'codeaw.appearance');
  Future<void> saveAppearance(String mode) => _storage.write(key: 'codeaw.appearance', value: mode);
  static const _key = 'codeaw.host';
  final _storage = const FlutterSecureStorage();
  Future<void> _pendingWrite = Future.value();

  Future<HostLibrary> load() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null) return HostLibrary();
      return HostLibrary.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return HostLibrary();
    }
  }

  Future<void> save(HostLibrary library) {
    final value = jsonEncode(library.toJson());
    final write = _pendingWrite.then(
      (_) => _storage.write(key: _key, value: value),
    );
    // URL preferences and user selections must reach storage in the same order.
    _pendingWrite = write.catchError((Object _) {});
    return write;
  }
}

/// Contents of a `codeaw://pair?u=…&u=…&c=…&n=…` link (the QR code printed by the bridge).
class PairingLink {
  PairingLink(this.urls, this.code, this.hostName);
  final List<String> urls;
  final String code;
  final String? hostName;

  /// Browser launches use the serving bridge's origin, never a URL from the query.
  static PairingLink? fromBrowserUri(Uri uri) {
    if (!const ['http', 'https'].contains(uri.scheme) || uri.host.isEmpty) return null;
    final route = uri.fragment.startsWith('/') ? Uri.tryParse(uri.fragment) : null;
    final params = uri.queryParameters.containsKey('pair')
        ? uri.queryParameters
        : route?.queryParameters;
    if (params == null || !params.containsKey('pair')) return null;
    final code = params['c']?.trim();
    if (code == null || code.isEmpty) return null;
    return PairingLink([bridgeWebSocketUrl(uri.origin)], code, params['n']);
  }

  static PairingLink? parse(String text) {
    final uri = Uri.tryParse(text.trim());
    if (uri == null || uri.scheme != 'codeaw' || uri.host != 'pair') return null;
    final urls = uri.queryParametersAll['u'] ?? const [];
    final code = uri.queryParameters['c'];
    if (urls.isEmpty || code == null) return null;
    return PairingLink(urls, code, uri.queryParameters['n']);
  }
}

class PairingException implements Exception {
  PairingException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Exchanges a one-time code, or reuses a verified pairing when reopening the desktop app.
Future<HostConfig> pairWithBridge(PairingLink link, String deviceName, {HostConfig? existingHost}) async {
  final errors = <String>[];
  final client = http.Client();
  try {
    for (final url in link.urls) {
      final uri = HostConfig.httpBase(url).replace(path: '/api/pair');
      try {
        if (existingHost != null && existingHost.urls.any((saved) => HostConfig.httpBase(saved).origin == uri.origin)) {
          try {
            final check = await client.get(uri.replace(path: '/api/device'), headers: {'Authorization': 'Bearer ${existingHost.token}'})
                .timeout(const Duration(seconds: 4));
            if (check.statusCode == 200) {
              return existingHost.withUrls([url, ...existingHost.urls.where((saved) => saved != url)]);
            }
          } catch (_) {
            // An unavailable or revoked saved pairing falls back to the new code.
          }
        }
        final res = await client
            .post(uri, headers: {'Content-Type': 'application/json'}, body: jsonEncode({'code': link.code, 'deviceName': deviceName}))
            .timeout(const Duration(seconds: 8));
        final body = utf8.decode(res.bodyBytes);
        final json = body.isEmpty ? <String, dynamic>{} : jsonDecode(body) as Map<String, dynamic>;
        if (res.statusCode != 200) {
          throw PairingException('${json['error'] ?? 'HTTP ${res.statusCode}'}');
        }
        final bridge = json['bridge'] as Map<String, dynamic>? ?? const {};
        return HostConfig(
          name: (bridge['name'] as String?) ?? link.hostName ?? uri.host,
          urls: [url, ...link.urls.where((u) => u != url)],
          token: json['token'] as String,
          deviceId: json['deviceId'] as String? ?? '',
          deviceName: deviceName,
        );
      } on PairingException {
        rethrow;
      } catch (e) {
        errors.add('$url：$e');
      }
    }
  } finally {
    client.close();
  }
  throw PairingException('連不上 bridge。請確認手機已連上 Tailscale、電腦上的 bridge 正在執行。\n${errors.join('\n')}');
}
