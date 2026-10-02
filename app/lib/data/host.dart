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

class HostStore {
  static const _key = 'codeaw.host';
  final _storage = const FlutterSecureStorage();

  Future<HostConfig?> load() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null) return null;
      return HostConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(HostConfig host) => _storage.write(key: _key, value: jsonEncode(host.toJson()));

  Future<void> clear() => _storage.delete(key: _key);
}

/// Contents of a `codeaw://pair?u=…&u=…&c=…&n=…` link (the QR code printed by the bridge).
class PairingLink {
  PairingLink(this.urls, this.code, this.hostName);
  final List<String> urls;
  final String code;
  final String? hostName;

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

/// Exchanges a one-time code for a device token, trying each URL until one answers.
Future<HostConfig> pairWithBridge(PairingLink link, String deviceName) async {
  final errors = <String>[];
  final client = http.Client();
  try {
    for (final url in link.urls) {
      final uri = HostConfig.httpBase(url).replace(path: '/api/pair');
      try {
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
