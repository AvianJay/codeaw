import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

typedef CpaRequest =
    Future<dynamic> Function(String method, Map<String, dynamic> params);

class CpaSettings {
  const CpaSettings({required this.endpoint, required this.managementKey});
  final String endpoint;
  final String managementKey;
  Map<String, dynamic> toJson() => {
    'endpoint': endpoint,
    'managementKey': managementKey,
  };
  factory CpaSettings.fromJson(Map<String, dynamic> json) => CpaSettings(
    endpoint: json['endpoint'] as String? ?? '',
    managementKey: json['managementKey'] as String? ?? '',
  );
}

class CpaStore {
  CpaStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;
  static const _key = 'codeaw.cpa.connection.v1';
  Future<CpaSettings?> load() async {
    final value = await _storage.read(key: _key);
    if (value == null) return null;
    return CpaSettings.fromJson(jsonDecode(value) as Map<String, dynamic>);
  }

  Future<void> save(CpaSettings settings) =>
      _storage.write(key: _key, value: jsonEncode(settings.toJson()));
  Future<void> clear() => _storage.delete(key: _key);
}

class CpaWindow {
  CpaWindow.fromJson(Map<String, dynamic> j)
    : id = j['id'] as String? ?? '',
      label = j['label'] as String? ?? '額度',
      remainingPercent = (j['remainingPercent'] as num?)?.toDouble(),
      resetAt = DateTime.tryParse(j['resetAt'] as String? ?? '');
  final String id, label;
  final double? remainingPercent;
  final DateTime? resetAt;
}

class CpaQuota {
  CpaQuota.fromJson(Map<String, dynamic> j)
    : windows = (j['windows'] as List? ?? [])
          .map((v) => CpaWindow.fromJson(Map<String, dynamic>.from(v as Map)))
          .toList(),
      resetsRemaining = (j['resetsRemaining'] as num?)?.toInt(),
      plan = j['plan'] as String?,
      subscriptionUntil = DateTime.tryParse(
        j['subscriptionUntil'] as String? ?? '',
      ),
      status = j['status'] as String? ?? 'error',
      message = j['message'] as String?,
      checkedAt = DateTime.tryParse(j['checkedAt'] as String? ?? '');
  final List<CpaWindow> windows;
  final int? resetsRemaining;
  final String? plan, message;
  final String status;
  final DateTime? subscriptionUntil, checkedAt;
}

class CpaAccount {
  CpaAccount.fromJson(Map<String, dynamic> j)
    : id = j['id'] as String,
      label = j['label'] as String? ?? '帳號',
      provider = j['provider'] as String? ?? 'unknown',
      plan = j['plan'] as String?,
      disabled = j['disabled'] == true,
      unavailable = j['unavailable'] == true,
      requests = (j['requests'] as num?)?.toInt(),
      status = j['status'] as String? ?? 'unknown';
  final String id, label, provider, status;
  final String? plan;
  final bool disabled, unavailable;
  final int? requests;
  String get providerLabel => switch (provider) {
    'codex' => 'Codex',
    'claude' => 'Claude',
    'grok' => 'Grok',
    'antigravity' => 'Antigravity',
    'gemini' => 'Gemini',
    'kimi' => 'Kimi',
    'qwen' => 'Qwen',
    'devin' => 'Devin',
    'unknown' => '其他',
    _ => provider,
  };
}

class CpaController extends ChangeNotifier {
  CpaController({required this.request, CpaStore? store})
    : store = store ?? CpaStore();
  final CpaRequest request;
  final CpaStore store;
  CpaSettings? settings;
  List<CpaAccount> accounts = [];
  final Map<String, CpaQuota> quotas = {};
  final Set<String> loadingQuotas = {};
  bool initialized = false, loading = false;
  String? error;
  DateTime? updatedAt;
  int _generation = 0;
  bool _disposed = false;
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    try {
      settings = await store.load();
    } catch (_) {
      error = '無法讀取 CPA 設定，請重新設定連線';
    }
    initialized = true;
    _changed();
    if (settings != null) await refresh();
  }

  Future<void> configure(CpaSettings value) async {
    final uri = Uri.tryParse(value.endpoint.trim());
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('請輸入有效的 HTTP(S) CPA 網址');
    }
    if (value.managementKey.trim().isEmpty) {
      throw const FormatException('請輸入 Management Key');
    }
    final next = CpaSettings(
      endpoint: value.endpoint.trim().replaceFirst(RegExp(r'/+$'), ''),
      managementKey: value.managementKey.trim(),
    );
    await store.save(next);
    _generation++;
    settings = next;
    accounts = [];
    quotas.clear();
    loadingQuotas.clear();
    await refresh();
  }

  Future<void> forget() async {
    await store.clear();
    _generation++;
    settings = null;
    accounts = [];
    quotas.clear();
    loadingQuotas.clear();
    loading = false;
    error = null;
    updatedAt = null;
    _changed();
  }

  Future<void> refresh() async {
    final connection = settings;
    if (connection == null || _disposed) return;
    final generation = ++_generation;
    loading = true;
    error = null;
    loadingQuotas.clear();
    _changed();
    try {
      final result = Map<String, dynamic>.from(
        await request(
              '_codeaw/cpa/accounts',
              connection.toJson(),
            ).timeout(const Duration(seconds: 20))
            as Map,
      );
      if (_disposed || generation != _generation) return;
      accounts = (result['accounts'] as List)
          .map((v) => CpaAccount.fromJson(Map<String, dynamic>.from(v as Map)))
          .toList();
      // Never present a previous failed refresh as a fresh quota value.
      quotas.clear();
      loadingQuotas.addAll(accounts.where((a) => !a.disabled).map((a) => a.id));
      updatedAt = DateTime.tryParse(result['checkedAt'] as String? ?? '');
      loading = false;
      _changed();
      var index = 0;
      Future<void> worker() async {
        while (index < accounts.length &&
            generation == _generation &&
            !_disposed) {
          final account = accounts[index++];
          if (account.disabled) continue;
          await _quota(account.id, generation, connection);
        }
      }

      await Future.wait(List.generate(3, (_) => worker()));
    } catch (e) {
      if (_disposed || generation != _generation) return;
      loading = false;
      error = _safeError(e, connection.managementKey);
      _changed();
    }
  }

  Future<void> refreshAccount(String id) async {
    if (settings == null || loadingQuotas.contains(id)) return;
    loadingQuotas.add(id);
    _changed();
    await _quota(id, _generation, settings!);
  }

  Future<void> _quota(String id, int generation, CpaSettings connection) async {
    CpaQuota quota;
    try {
      final result = await request('_codeaw/cpa/quota', {
        ...connection.toJson(),
        'accountId': id,
      }).timeout(const Duration(seconds: 30));
      quota = CpaQuota.fromJson(Map<String, dynamic>.from(result as Map));
    } catch (e) {
      quota = CpaQuota.fromJson({
        'status': 'error',
        'message': _safeError(e, connection.managementKey),
      });
    }
    if (_disposed || generation != _generation) return;
    quotas[id] = quota;
    loadingQuotas.remove(id);
    _changed();
  }

  static String _safeError(Object error, String secret) {
    var message = error is TimeoutException ? 'CPA 查詢逾時，請重試' : error.toString();
    if (message.contains('Method not found') || message.contains('-32601')) {
      message = '請先更新電腦 bridge，以支援 CPA 用量查詢';
    }
    return secret.isEmpty ? message : message.replaceAll(secret, '••••');
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}

String cpaResetCountdown(DateTime? resetAt, DateTime now) {
  if (resetAt == null) return '重置時間未知';
  final remaining = resetAt.difference(now);
  if (remaining <= Duration.zero) return '已到重置時間 · 請重新整理';
  final minutes = remaining.inMinutes;
  if (minutes == 0) return '不到 1 分後重置';
  final days = minutes ~/ 1440, hours = (minutes % 1440) ~/ 60;
  if (days > 0) return '$days 天 $hours 小時後重置';
  if (hours > 0) return '$hours 小時 ${minutes % 60} 分後重置';
  return '$minutes 分後重置';
}

String cpaResetDate(DateTime? date) {
  if (date == null) return '—';
  final d = date.toLocal();
  return '${d.month}/${d.day} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}
