import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
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
      periodSeconds = (j['periodSeconds'] as num?)?.toInt(),
      resetAt = DateTime.tryParse(j['resetAt'] as String? ?? '');
  final String id, label;
  final double? remainingPercent;
  final int? periodSeconds;
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

class CpaUsageAverage {
  const CpaUsageAverage(this.remainingPercent, this.accountCount);
  final double? remainingPercent;
  final int accountCount;
}

class CpaProviderAverage {
  const CpaProviderAverage({
    required this.provider,
    required this.label,
    required this.totalAccounts,
    required this.weekly,
    required this.fiveHour,
  });
  final String provider, label;
  final int totalAccounts;
  final CpaUsageAverage weekly, fiveHour;
}

/// Each account has equal weight, independently for each provider and window.
/// AGY averages model groups within an account before averaging accounts.
List<CpaProviderAverage> cpaProviderAverages(
  List<CpaAccount> accounts,
  Map<String, CpaQuota> quotas,
) {
  final groups = <String, List<CpaAccount>>{};
  for (final account in accounts) {
    groups.putIfAbsent(account.provider, () => []).add(account);
  }
  CpaUsageAverage average(List<CpaAccount> group, String id, int seconds) {
    final values = <double>[];
    for (final account in group) {
      final quota = quotas[account.id];
      if (account.disabled || account.unavailable || quota?.status != 'ok') {
        continue;
      }
      final mainWindows = quota!.windows.where((w) => w.id == id).toList();
      // Codex review and Claude model-specific windows are separate allowances.
      final windows =
          mainWindows.isNotEmpty ||
              account.provider == 'codex' ||
              account.provider == 'claude'
          ? mainWindows
          : quota.windows.where((w) => w.periodSeconds == seconds);
      final remaining = windows
          .map((w) => w.remainingPercent)
          .whereType<double>()
          .where((v) => v.isFinite && v >= 0 && v <= 100)
          .toList();
      if (remaining.isNotEmpty) {
        values.add(remaining.reduce((a, b) => a + b) / remaining.length);
      }
    }
    return CpaUsageAverage(
      values.isEmpty ? null : values.reduce((a, b) => a + b) / values.length,
      values.length,
    );
  }

  const order = ['codex', 'claude', 'antigravity', 'grok'];
  final providers = groups.keys.toList()
    ..sort((a, b) {
      final ai = order.indexOf(a), bi = order.indexOf(b);
      if (ai >= 0 || bi >= 0) {
        return (ai < 0 ? order.length : ai).compareTo(
          bi < 0 ? order.length : bi,
        );
      }
      return a.compareTo(b);
    });
  return [
    for (final provider in providers)
      CpaProviderAverage(
        provider: provider,
        label: provider == 'antigravity'
            ? 'AGY'
            : groups[provider]!.first.providerLabel,
        totalAccounts: groups[provider]!.length,
        weekly: average(groups[provider]!, 'weekly', 604800),
        fiveHour: average(groups[provider]!, 'five-hour', 18000),
      ),
  ];
}

class CpaController extends ChangeNotifier with WidgetsBindingObserver {
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
  Timer? _refreshTimer;
  bool _autoRefresh = false;
  Future<void>? _initializing;

  /// Shared by the chat header and usage page; mounting both never adds a poller.
  void startAutoRefresh() {
    if (_autoRefresh || _disposed) return;
    _autoRefresh = true;
    WidgetsBinding.instance.addObserver(this);
    _scheduleAutoRefresh();
  }

  void _scheduleAutoRefresh() {
    if (!_autoRefresh || _refreshTimer != null || settings == null || _disposed) {
      return;
    }
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => refreshIfActive(),
    );
  }

  void refreshIfActive() {
    if (_disposed ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed ||
        settings == null ||
        loading ||
        loadingQuotas.isNotEmpty) {
      return;
    }
    unawaited(refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refreshIfActive();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    try {
      final saved = await store.load();
      if (_disposed) return;
      settings = saved;
    } catch (_) {
      error = '無法讀取 CPA 設定，請重新設定連線';
    }
    initialized = true;
    _scheduleAutoRefresh();
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
    if (_disposed) return;
    _generation++;
    settings = next;
    _scheduleAutoRefresh();
    accounts = [];
    quotas.clear();
    loadingQuotas.clear();
    await refresh();
  }

  Future<void> forget() async {
    await store.clear();
    if (_disposed) return;
    _generation++;
    settings = null;
    _refreshTimer?.cancel();
    _refreshTimer = null;
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
    if (_autoRefresh) WidgetsBinding.instance.removeObserver(this);
    _refreshTimer?.cancel();
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
