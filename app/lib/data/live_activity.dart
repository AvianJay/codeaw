import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'bridge_client.dart';

typedef NativeActivityCall =
    Future<dynamic> Function(String, Map<String, dynamic>?);

/// Owns iOS Live Activities across chat navigation; chat attachment is not required
/// for work updates. APNs subscriptions remain on the bridge after socket suspension.
class LiveActivityController extends ChangeNotifier {
  LiveActivityController({
    NativeActivityCall? nativeCall,
    bool? platformSupported,
  }) : _call =
           nativeCall ??
           ((method, params) => _channel.invokeMethod(method, params)),
       supported =
           platformSupported ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS);

  static const _channel = MethodChannel('codeaw/live_activity');
  final NativeActivityCall _call;
  bool supported;
  bool authorized = true;
  bool enabled = true;
  bool showDetails = true;
  bool remoteEnabled = false;
  bool remoteReady = false;
  bool remoteDetails = false;
  bool locationSupported = false;
  bool locationEnabled = false;
  bool locationActive = false;
  bool locationServicesEnabled = true;
  String locationAuthorization = 'notDetermined';
  String? locationError;
  bool get pushRegistered => _registered.isNotEmpty;
  String? error;
  BridgeClient? _client;
  String? _hostKey;
  final _followed = <String>{};
  final _snapshots = <String, Map<String, dynamic>>{};
  final _receivedAt = <String, int>{};
  final _snapshotRevision = <String, int>{};
  int _revision = 0;
  final _tokens = <String, Map<String, dynamic>>{};
  final _registered = <String, String>{};
  StreamSubscription<Map<String, dynamic>>? _activitySub;
  StreamSubscription<void>? _connectedSub;
  Future<void> _serial = Future.value();
  bool _disposed = false;
  bool _initialized = false;
  bool _handlerInstalled = false;
  bool _foreground = true;
  bool get foreground => _foreground;
  set foreground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    if (value) _syncLocation(force: true);
  }

  Timer? _heartbeat;
  Future<void>? _refreshing;
  int _generation = 0;
  ({bool enabled, bool running})? _locationTarget;

  Future<void> initialize() async {
    if (!supported) return;
    final prefs = await SharedPreferences.getInstance();
    if (_disposed) return;
    enabled = prefs.getBool('codeaw.liveActivity.enabled') ?? true;
    showDetails = prefs.getBool('codeaw.liveActivity.details') ?? true;
    locationEnabled = prefs.getBool('codeaw.liveActivity.location') ?? false;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (_disposed) return;
      if (call.method == 'token' && call.arguments is Map) {
        await _register(Map<String, dynamic>.from(call.arguments as Map));
      } else if (call.method == 'locationStatus' && call.arguments is Map) {
        _readLocation(call.arguments as Map);
        for (final snapshot in _snapshots.values.toList()) {
          accept(snapshot, fresh: false);
        }
      } else if (call.method == 'locationWake') {
        if (locationActive && (_client?.isOnline ?? false)) {
          unawaited(refresh());
        }
      } else if (call.method == 'ended' && call.arguments is Map) {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        if (args['hostKey'] == _hostKey) {
          final id = '${args['activityId']}';
          _tokens.remove(id);
          _registered.remove(id);
          await _unregister(id);
          _changed();
        }
      }
    });
    var nativeReady = false;
    try {
      final info = await _native('status', null) as Map;
      if (_disposed) return;
      supported = info['supported'] == true;
      authorized = info['authorized'] == true;
      _readLocation(info['location'] as Map?);
      nativeReady = true;
    } catch (_) {
      error = '無法啟用即時動態，請確認 iOS 版本與簽名保留 Widget extension';
    }
    if (_disposed) return;
    _initialized = true;
    _scheduleHeartbeat();
    for (final snapshot in _snapshots.values.toList()) {
      accept(snapshot, fresh: false);
    }
    if (nativeReady && (_client?.isOnline ?? false)) unawaited(refresh());
    _changed();
  }

  Future<dynamic> _native(String method, Map<String, dynamic>? params) =>
      _call(method, params).timeout(const Duration(seconds: 5));

  void bind(BridgeClient client) {
    unbind();
    _client = client;
    _hostKey = client.host.deviceId;
    _activitySub = client.activity.listen(accept);
    _connectedSub = client.connected.listen((_) {
      _registered.clear();
      unawaited(refresh());
    });
    if (client.isOnline) unawaited(refresh());
  }

  void follow(String sessionId) {
    if (!supported) return;
    _followed.add(sessionId);
    final known = _snapshots[sessionId];
    if (known != null) accept(known, fresh: false);
    if (_client?.isOnline ?? false) unawaited(refresh());
  }

  Future<void> refresh() {
    final current = _refreshing;
    if (current != null) return current;
    final operation = _refresh();
    _refreshing = operation;
    unawaited(
      operation.whenComplete(() {
        if (identical(_refreshing, operation)) _refreshing = null;
      }),
    );
    return operation;
  }

  Future<void> _refresh() async {
    final client = _client;
    final generation = _generation;
    if (!_initialized || !supported || client == null || !client.isOnline) {
      return;
    }
    try {
      final info = await client.request('_codeaw/live_activity/info') as Map;
      if (generation != _generation || _disposed) return;
      remoteEnabled = info['enabled'] == true;
      remoteReady = info['ready'] == true;
      remoteDetails = info['includeDetails'] == true;
      error = info['error'] as String?;
      final native = await _native('status', null) as Map;
      if (generation != _generation || _disposed) return;
      authorized = native['authorized'] == true;
      _readLocation(native['location'] as Map?);
      for (final raw
          in (native['activities'] as List? ?? const []).whereType<Map>()) {
        if (raw['hostKey'] == _hostKey) _followed.add('${raw['sessionId']}');
      }
      for (final raw
          in (native['tokens'] as List? ?? const []).whereType<Map>()) {
        final token = Map<String, dynamic>.from(raw);
        if (token['hostKey'] != _hostKey) continue;
        _followed.add('${token['sessionId']}');
        await _register(token);
      }
      final revision = _revision;
      final list = await client.request('_codeaw/activity/list') as Map;
      if (generation != _generation || _disposed) return;
      final seen = <String>{};
      for (final raw
          in (list['activities'] as List? ?? const []).whereType<Map>()) {
        final id = raw['sessionId'];
        if (id is! String) continue;
        seen.add(id);
        if ((_snapshotRevision[id] ?? 0) <= revision) {
          accept(Map<String, dynamic>.from(raw));
        }
      }
      _snapshots.removeWhere(
        (id, _) =>
            !seen.contains(id) && (_snapshotRevision[id] ?? 0) <= revision,
      );
      _receivedAt.removeWhere((id, _) => !_snapshots.containsKey(id));
      _snapshotRevision.removeWhere((id, _) => !_snapshots.containsKey(id));
      _scheduleHeartbeat();
      _changed();
    } catch (_) {
      // An older bridge still works for chat; explain the feature's prerequisite.
      if (generation == _generation) {
        error = '即時動態暫時無法同步，請檢查 bridge 版本及 iOS 設定；回到 App 或重連後會再嘗試';
        _changed();
      }
    }
  }

  void accept(Map<String, dynamic> snapshot, {bool fresh = true}) {
    final id = snapshot['sessionId'];
    if (id is! String) return;
    _snapshots[id] = snapshot;
    if (fresh) {
      _receivedAt[id] = DateTime.now().millisecondsSinceEpoch;
      _snapshotRevision[id] = ++_revision;
    }
    if (snapshot['work'] is Map &&
        snapshot['state'] != 'idle' &&
        snapshot['deleted'] != true) {
      // Track concurrent work across the paired bridge, even without opening each chat.
      _followed.add(id);
    }
    _scheduleHeartbeat();
    if (!_initialized || !supported || !enabled || !_followed.contains(id)) {
      return;
    }
    final hostKey = _hostKey;
    final generation = _generation;
    final work = snapshot['work'] as Map?;
    if (work == null && snapshot['deleted'] != true) return;
    final completed = snapshot['completedTurn'] as Map?;
    final idle = snapshot['state'] == 'idle' || snapshot['deleted'] == true;
    final turnId = idle ? (completed?['promptId']) : snapshot['turnPromptId'];
    if (turnId == null && snapshot['deleted'] != true) return;
    final params = <String, dynamic>{
      'hostKey': hostKey,
      'sessionId': id,
      'turnId': turnId,
      'title': showDetails
          ? (snapshot['title'] ?? work?['project'] ?? '聊天')
          : 'Codeaw',
      'project': showDetails ? (work?['project'] ?? '專案') : 'Codeaw',
      'agent': snapshot['agentId'] ?? '',
      'state': idle ? 'idle' : snapshot['state'],
      'phase': work?['phase'] ?? 'completed',
      'summary': showDetails
          ? (work?['summary'] ?? '')
          : work?['phase'] == 'error'
          ? '執行失敗'
          : work?['phase'] == 'cancelled'
          ? '已停止'
          : work?['phase'] == 'disconnected'
          ? '等待重新同步'
          : idle
          ? '已完成'
          : snapshot['state'] == 'requires_action'
          ? '等待你的回覆'
          : 'AI 正在工作…',
      'startedAt': snapshot['turnStartedAt'] ?? completed?['startedAt'],
      'endedAt': completed?['endedAt'],
      'updatedAt': _receivedAt[id] ?? DateTime.now().millisecondsSinceEpoch,
      'usePush': remoteReady,
      'locationUpdates': locationActive,
      'backgroundUpdates': _tokens.entries.any(
        (entry) =>
            _registered.containsKey(entry.key) &&
            entry.value['sessionId'] == id &&
            entry.value['turnId'] == turnId,
      ),
    };
    _serial = _serial.then((_) async {
      if (_disposed || generation != _generation || !enabled) return;
      try {
        params['locationUpdates'] = locationActive;
        final result = await _native('sync', params) as Map?;
        if (result?['error'] is String) {
          error = result!['error'] as String;
          _changed();
        }
        for (final raw
            in (result?['tokens'] as List? ?? const []).whereType<Map>()) {
          await _register(Map<String, dynamic>.from(raw));
        }
      } catch (_) {
        error = '即時動態無法更新，請檢查 iOS 設定中的「即時動態」';
        _changed();
      }
    });
  }

  bool get _hasRunningWork =>
      supported &&
      enabled &&
      authorized &&
      _client != null &&
      _snapshots.entries.any(
        (entry) =>
            _followed.contains(entry.key) &&
            entry.value['work'] is Map &&
            entry.value['state'] != 'idle' &&
            entry.value['deleted'] != true,
      );

  void _scheduleHeartbeat() {
    _syncLocation();
    if (!_hasRunningWork) {
      _heartbeat?.cancel();
      _heartbeat = null;
    } else {
      _heartbeat ??= Timer.periodic(const Duration(seconds: 60), (_) {
        if ((foreground || locationActive) && (_client?.isOnline ?? false)) {
          unawaited(refresh());
        }
      });
    }
  }

  void _readLocation(Map? info) {
    if (info == null) return;
    locationSupported = info['supported'] == true;
    locationActive = info['active'] == true;
    locationServicesEnabled = info['servicesEnabled'] == true;
    locationAuthorization = info['authorization'] as String? ?? 'notDetermined';
    locationError = info['error'] as String?;
    _changed();
  }

  void _syncLocation({bool requestPermission = false, bool force = false}) {
    if (!_initialized || !supported || !locationSupported) return;
    final target = (
      enabled: enabled && locationEnabled && _client != null,
      running: _hasRunningWork,
    );
    if (!force && !requestPermission && target == _locationTarget) return;
    _locationTarget = target;
    final generation = _generation;
    _serial = _serial.then((_) async {
      if (_disposed || generation != _generation || target != _locationTarget) {
        return;
      }
      try {
        final result = await _native('backgroundLocation', {
          'enabled': target.enabled,
          'running': target.running,
          'requestPermission': requestPermission,
        });
        if (generation == _generation && result is Map) _readLocation(result);
      } catch (_) {
        locationActive = false;
        locationError = '背景定位無法啟用，請更新 App 並檢查 iPhone 的定位設定';
        _changed();
      }
    });
  }

  Future<void> _register(Map<String, dynamic> token) async {
    final client = _client;
    if (!enabled || client == null || token['hostKey'] != _hostKey) return;
    final id = '${token['activityId']}';
    _tokens[id] = token;
    final identity = '${token['pushToken']}:$showDetails';
    if (!remoteEnabled || !client.isOnline || _registered[id] == identity) {
      return;
    }
    try {
      final result =
          await client.request('_codeaw/live_activity/register', {
                ...token,
                'includeDetails': showDetails,
              })
              as Map;
      if (identical(client, _client) && result['registered'] == true) {
        _registered[id] = identity;
        final snapshot = _snapshots[token['sessionId']];
        if (snapshot != null) accept(snapshot, fresh: false);
        _changed();
      }
    } catch (_) {
      /* A finished or dismissed turn no longer needs registration. */
    }
  }

  Future<void> _unregister(String id) async {
    try {
      await _client?.request('_codeaw/live_activity/unregister', {
        'activityId': id,
      });
    } catch (_) {}
  }

  Future<void> configure({
    bool? enabled,
    bool? showDetails,
    bool? locationEnabled,
  }) async {
    this.enabled = enabled ?? this.enabled;
    this.showDetails = showDetails ?? this.showDetails;
    this.locationEnabled = locationEnabled ?? this.locationEnabled;
    _syncLocation(requestPermission: locationEnabled == true);
    _scheduleHeartbeat();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('codeaw.liveActivity.enabled', this.enabled);
    await prefs.setBool('codeaw.liveActivity.details', this.showDetails);
    await prefs.setBool('codeaw.liveActivity.location', this.locationEnabled);
    await _serial;
    if (!this.enabled) {
      for (final id in _tokens.keys.toList()) {
        await _unregister(id);
      }
      _tokens.clear();
      _registered.clear();
      if (supported) {
        try {
          await _native('endAll', {'hostKey': _hostKey});
        } catch (_) {
          error = 'iOS 暫時無法關閉即時動態，請在鎖定畫面手動移除';
        }
      }
    } else {
      for (final token in _tokens.values.toList()) {
        await _register(token);
      }
      for (final snapshot in _snapshots.values.toList()) {
        accept(snapshot, fresh: false);
      }
      await _serial;
      await refresh();
    }
    _changed();
  }

  void unbind() {
    final old = _client;
    final key = _hostKey;
    for (final id in _tokens.keys) {
      if (old?.isOnline ?? false) {
        unawaited(
          old!
              .request('_codeaw/live_activity/unregister', {'activityId': id})
              .catchError((Object _) => null),
        );
      }
    }
    if (_initialized && supported && key != null) {
      _serial = _serial.then((_) async {
        try {
          if (locationSupported) {
            await _native('backgroundLocation', {
              'enabled': false,
              'running': false,
              'requestPermission': false,
            });
          }
          await _native('endAll', {'hostKey': key});
        } catch (_) {}
      });
    }
    _generation++;
    _refreshing = null;
    _activitySub?.cancel();
    _connectedSub?.cancel();
    _heartbeat?.cancel();
    _heartbeat = null;
    _client = null;
    _hostKey = null;
    _followed.clear();
    _snapshots.clear();
    _receivedAt.clear();
    _snapshotRevision.clear();
    _tokens.clear();
    _registered.clear();
    _locationTarget = null;
    locationActive = false;
    locationError = null;
    remoteEnabled = remoteReady = remoteDetails = false;
    error = null;
  }

  Future<void> get settled => _serial;
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    unbind();
    _disposed = true;
    if (_handlerInstalled) _channel.setMethodCallHandler(null);
    super.dispose();
  }
}
