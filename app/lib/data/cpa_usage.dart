import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../acp/jsonrpc.dart';

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
  static const _ignoredAccountsKey = 'codeaw.cpa.ignored-accounts.v1';
  Future<CpaSettings?> load() async {
    final value = await _storage.read(key: _key);
    if (value == null) return null;
    return CpaSettings.fromJson(jsonDecode(value) as Map<String, dynamic>);
  }

  Future<void> save(CpaSettings settings) =>
      _storage.write(key: _key, value: jsonEncode(settings.toJson()));
  Future<void> clear() => _storage.delete(key: _key);

  Future<Set<String>> loadIgnoredAccounts() async {
    final value = await _storage.read(key: _ignoredAccountsKey);
    if (value == null) return {};
    try {
      final decoded = jsonDecode(value);
      if (decoded is! List) return {};
      return decoded.whereType<String>().where((id) => id.isNotEmpty).toSet();
    } catch (_) {
      return {};
    }
  }

  Future<void> saveIgnoredAccounts(Iterable<String> ids) {
    final sorted = ids.where((id) => id.isNotEmpty).toSet().toList()..sort();
    return _storage.write(key: _ignoredAccountsKey, value: jsonEncode(sorted));
  }
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
      retryAt = DateTime.tryParse(j['retryAt'] as String? ?? ''),
      checkedAt = DateTime.tryParse(j['checkedAt'] as String? ?? '');
  final List<CpaWindow> windows;
  final int? resetsRemaining;
  final String? plan, message;
  final String status;
  final DateTime? subscriptionUntil, checkedAt, retryAt;
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
  const CpaUsageAverage(
    this.remainingPercent,
    this.accountCount, {
    this.staleCount = 0,
  });
  final double? remainingPercent;
  final int accountCount;
  final int staleCount;
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
  Map<String, CpaQuota> quotas, {
  Set<String> ignoredAccounts = const {},
}) {
  final groups = <String, List<CpaAccount>>{};
  for (final account in accounts) {
    if (ignoredAccounts.contains(account.id)) continue;
    groups.putIfAbsent(account.provider, () => []).add(account);
  }
  CpaUsageAverage average(List<CpaAccount> group, String id, int seconds) {
    final values = <double>[];
    var staleCount = 0;
    for (final account in group) {
      final quota = quotas[account.id];
      if (account.disabled ||
          account.unavailable ||
          !['ok', 'stale'].contains(quota?.status)) {
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
        if (quota.status == 'stale') staleCount++;
      }
    }
    return CpaUsageAverage(
      values.isEmpty ? null : values.reduce((a, b) => a + b) / values.length,
      values.length,
      staleCount: staleCount,
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
  CpaController({required this.request, CpaStore? store, this.onQuotaRecovered})
    : store = store ?? CpaStore();
  final CpaRequest request;
  final CpaStore store;
  final void Function(String provider)? onQuotaRecovered;
  CpaSettings? settings;
  bool bridgeManaged = false;
  List<CpaAccount> accounts = [];
  final Map<String, CpaQuota> quotas = {};
  final Set<String> ignoredAccounts = {};
  final Set<String> loadingQuotas = {};
  bool initialized = false, loading = false;
  String? error;
  DateTime? updatedAt;
  int _generation = 0;
  bool _disposed = false;
  Timer? _refreshTimer;
  bool _autoRefresh = false;
  Future<void>? _initializing;
  Future<void> _ignoredWrite = Future.value();
  final _providerAvailable = <String, bool>{};
  bool _bridgeSupported = false;
  bool _bridgeStatusAttempted = false;

  /// Shared by the chat header and usage page; mounting both never adds a poller.
  void startAutoRefresh() {
    if (_autoRefresh || _disposed) return;
    _autoRefresh = true;
    WidgetsBinding.instance.addObserver(this);
    _scheduleAutoRefresh();
  }

  void _scheduleAutoRefresh() {
    if (!_autoRefresh ||
        _refreshTimer != null ||
        settings == null ||
        _disposed) {
      return;
    }
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => refreshIfActive(),
    );
  }

  void refreshIfActive() {
    if (!_disposed && !_bridgeStatusAttempted) {
      unawaited(_retryBridgeStatus());
      if (settings == null) return;
    }
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

  Future<Map<String, dynamic>?> _bridgeStatus() async {
    try {
      final result = await request('_codeaw/cpa/status', const {});
      _bridgeStatusAttempted = true;
      final map = Map<String, dynamic>.from(result as Map);
      if (map['supported'] == true) {
        _bridgeSupported = true;
        return map;
      }
      return null;
    } on RpcError catch (error) {
      if (error.code == RpcError.methodNotFound) {
        _bridgeStatusAttempted = true;
        return null;
      }
      rethrow;
    }
  }

  Future<void> _retryBridgeStatus() async {
    try {
      final remote = await _bridgeStatus();
      if (remote?['configured'] != true || remote?['endpoint'] is! String || _disposed) return;
      bridgeManaged = true;
      settings = CpaSettings(endpoint: remote!['endpoint'] as String, managementKey: '');
      _scheduleAutoRefresh();
      _changed();
      await refresh();
    } catch (_) {
      // The reconnect listener will retry once the bridge is available.
    }
  }

  Future<void> _initialize() async {
    try {
      final saved = await store.load();
      final ignored = await store.loadIgnoredAccounts();
      if (_disposed) return;
      Map<String, dynamic>? remote;
      try {
        remote = await _bridgeStatus();
      } catch (_) {
        // The local fallback keeps the usage page usable while the bridge reconnects.
      }
      if (remote != null) {
        bridgeManaged = remote['configured'] == true;
        final endpoint = remote['endpoint'] as String?;
        settings = bridgeManaged && endpoint != null
            ? CpaSettings(endpoint: endpoint, managementKey: '')
            : null;
        if (bridgeManaged && saved != null) await store.clear();
        if (!bridgeManaged && saved != null) {
          try {
            await request('_codeaw/cpa/configure', saved.toJson());
            bridgeManaged = true;
            settings = CpaSettings(endpoint: saved.endpoint, managementKey: '');
            await store.clear();
          } catch (_) {
            _bridgeSupported = false;
            settings = saved;
          }
        }
      } else {
        settings = saved;
      }
      ignoredAccounts
        ..clear()
        ..addAll(ignored);
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
    if (value.managementKey.trim().isEmpty && !bridgeManaged) {
      throw const FormatException('請輸入 Management Key');
    }
    final next = CpaSettings(
      endpoint: value.endpoint.trim().replaceFirst(RegExp(r'/+$'), ''),
      managementKey: value.managementKey.trim(),
    );
    if (_bridgeSupported) {
      final result = Map<String, dynamic>.from(
        await request('_codeaw/cpa/configure', {
          'endpoint': next.endpoint,
          if (next.managementKey.isNotEmpty) 'managementKey': next.managementKey,
        }) as Map,
      );
      if (result['supported'] != true) {
        _bridgeSupported = false;
      } else {
        await store.clear();
        bridgeManaged = true;
      }
    }
    if (!_bridgeSupported) await store.save(next);
    if (_disposed) return;
    _generation++;
    settings = bridgeManaged
        ? CpaSettings(endpoint: next.endpoint, managementKey: '')
        : next;
    _scheduleAutoRefresh();
    _providerAvailable.clear();
    accounts = [];
    quotas.clear();
    loadingQuotas.clear();
    await refresh();
  }

  Future<void> forget() async {
    if (_bridgeSupported) {
      try {
        await request('_codeaw/cpa/forget', const {});
      } on RpcError catch (error) {
        if (error.code != RpcError.methodNotFound) rethrow;
      }
    }
    await store.clear();
    if (_disposed) return;
    _generation++;
    settings = null;
    bridgeManaged = false;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    accounts = [];
    quotas.clear();
    loadingQuotas.clear();
    loading = false;
    error = null;
    updatedAt = null;
    _providerAvailable.clear();
    _changed();
  }

  /// Excludes an account from provider averages and quota polling without
  /// changing the account in CPA. The choice is kept on this device.
  Future<void> setAccountIgnored(String id, bool ignored) async {
    if (id.isEmpty || ignoredAccounts.contains(id) == ignored) return;
    if (ignored) {
      ignoredAccounts.add(id);
      quotas.remove(id);
      loadingQuotas.remove(id);
    } else {
      ignoredAccounts.remove(id);
    }
    _recomputeProviderAvailability();
    _changed();
    final next = Set<String>.of(ignoredAccounts);
    _ignoredWrite = _ignoredWrite
        .catchError((_) {})
        .then((_) => store.saveIgnoredAccounts(next));
    await _ignoredWrite;
    if (!ignored &&
        settings != null &&
        accounts.any((account) => account.id == id)) {
      await refreshAccount(id);
    }
  }

  /// Marks a provider unavailable after a chat receives a quota error. The
  /// next successful quota poll can then be recognized as a recovery even if
  /// the previous poll still showed a positive cached value.
  void markProviderUnavailable(String provider) {
    if (provider.isEmpty || _disposed) return;
    _providerAvailable[provider] = false;
  }

  Map<String, dynamic> _requestParams(CpaSettings connection, {String? accountId}) => {
    if (!bridgeManaged) ...connection.toJson(),
    ...?accountId == null ? null : {'accountId': accountId},
  };

  Future<void> refresh() async {
    final connection = settings;
    if (connection == null || _disposed) return;
    final generation = ++_generation;
    final previousAccounts = List<CpaAccount>.of(accounts);
    loading = true;
    error = null;
    loadingQuotas.clear();
    _changed();
    try {
      final result = Map<String, dynamic>.from(
        await request(
              '_codeaw/cpa/accounts',
              _requestParams(connection),
            ).timeout(const Duration(seconds: 20))
            as Map,
      );
      if (_disposed || generation != _generation) return;
      final nextAccounts = (result['accounts'] as List)
          .map((v) => CpaAccount.fromJson(Map<String, dynamic>.from(v as Map)))
          .toList();
      final nextQuotas = <String, CpaQuota>{};
      // Keep the last complete snapshot visible until every account has settled.
      loadingQuotas.addAll(
        nextAccounts
            .where((a) => !a.disabled && !ignoredAccounts.contains(a.id))
            .map((a) => a.id),
      );
      _changed();
      var index = 0;
      Future<void> worker() async {
        while (index < nextAccounts.length &&
            generation == _generation &&
            !_disposed) {
          final account = nextAccounts[index++];
          if (account.disabled || ignoredAccounts.contains(account.id)) {
            continue;
          }
          final quota = await _fetchQuota(account.id, connection);
          if (_disposed || generation != _generation) return;
          nextQuotas[account.id] = quota;
          loadingQuotas.remove(account.id);
          _changed();
        }
      }

      await Future.wait(List.generate(3, (_) => worker()));
      if (_disposed || generation != _generation) return;
      accounts = nextAccounts;
      quotas
        ..clear()
        ..addAll({
          for (final entry in nextQuotas.entries)
            if (!ignoredAccounts.contains(entry.key)) entry.key: entry.value,
        });
      updatedAt = DateTime.now();
      loadingQuotas.clear();
      loading = false;
      final recovered = _updateProviderAvailability(previousAccounts);
      _changed();
      for (final provider in recovered) {
        if (!bridgeManaged) onQuotaRecovered?.call(provider);
      }
    } catch (e) {
      if (_disposed || generation != _generation) return;
      loading = false;
      loadingQuotas.clear();
      error = _safeError(e, connection.managementKey);
      _changed();
    }
  }

  Future<void> refreshAccount(String id) async {
    if (settings == null ||
        loading ||
        ignoredAccounts.contains(id) ||
        loadingQuotas.contains(id)) {
      return;
    }
    loadingQuotas.add(id);
    _changed();
    await _quota(id, _generation, settings!);
  }

  Future<void> _quota(String id, int generation, CpaSettings connection) async {
    final quota = await _fetchQuota(id, connection);
    if (_disposed || generation != _generation) return;
    final provider = accounts
        .where((account) => account.id == id)
        .firstOrNull
        ?.provider;
    final before = provider == null ? null : _providerAvailable[provider];
    quotas[id] = quota;
    loadingQuotas.remove(id);
    if (provider != null) {
      final after = _hasAvailableQuota(provider, accounts, quotas);
      _providerAvailable[provider] = after;
      if (before == false && after && !bridgeManaged) onQuotaRecovered?.call(provider);
    }
    _changed();
  }

  Set<String> _updateProviderAvailability(List<CpaAccount> previousAccounts) {
    final providers = {
      for (final account in previousAccounts) account.provider,
      for (final account in accounts) account.provider,
    };
    final recovered = <String>{};
    for (final provider in providers) {
      final before = _providerAvailable[provider];
      final after = _hasAvailableQuota(provider, accounts, quotas);
      _providerAvailable[provider] = after;
      if (before == false && after) recovered.add(provider);
    }
    return recovered;
  }

  void _recomputeProviderAvailability() {
    final providers = {for (final account in accounts) account.provider};
    for (final provider in providers) {
      _providerAvailable[provider] = _hasAvailableQuota(
        provider,
        accounts,
        quotas,
      );
    }
  }

  bool _hasAvailableQuota(
    String provider,
    List<CpaAccount> sourceAccounts,
    Map<String, CpaQuota> sourceQuotas,
  ) {
    for (final account in sourceAccounts) {
      if (account.provider != provider ||
          account.disabled ||
          account.unavailable ||
          ignoredAccounts.contains(account.id)) {
        continue;
      }
      final quota = sourceQuotas[account.id];
      if (quota?.status != 'ok') continue;
      final windows = provider == 'codex' || provider == 'claude'
          ? quota!.windows.where(
              (window) => window.id == 'weekly' || window.id == 'five-hour',
            )
          : quota!.windows.where(
              (window) =>
                  window.periodSeconds == 604800 ||
                  window.periodSeconds == 18000 ||
                  window.id == 'weekly',
            );
      if (windows.isNotEmpty && windows.every(
        (window) =>
            window.remainingPercent != null &&
            window.remainingPercent!.isFinite &&
            window.remainingPercent! > 0,
      )) {
        return true;
      }
    }
    return false;
  }

  Future<CpaQuota> _fetchQuota(String id, CpaSettings connection) async {
    CpaQuota quota;
    try {
      final result = await request('_codeaw/cpa/quota', {
        ..._requestParams(connection, accountId: id),
      }).timeout(const Duration(seconds: 30));
      quota = CpaQuota.fromJson(Map<String, dynamic>.from(result as Map));
    } catch (e) {
      quota = CpaQuota.fromJson({
        'status': 'error',
        'message': _safeError(e, connection.managementKey),
      });
    }
    return quota;
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
