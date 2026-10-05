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
  bool get pushRegistered => _registered.isNotEmpty;
  String? error;
  BridgeClient? _client;
  String? _hostKey;
  final _followed = <String>{};
  final _snapshots = <String, Map<String, dynamic>>{};
  final _tokens = <String, Map<String, dynamic>>{};
  final _registered = <String, String>{};
  StreamSubscription<Map<String, dynamic>>? _activitySub;
  StreamSubscription<void>? _connectedSub;
  Future<void> _serial = Future.value();
  bool _disposed = false;
  bool foreground = true;
  Timer? _heartbeat;
  Future<void>? _refreshing;
  int _generation = 0;

  Future<void> initialize() async {
    if (!supported) return;
    final prefs = await SharedPreferences.getInstance();
    enabled = prefs.getBool('codeaw.liveActivity.enabled') ?? true;
    showDetails = prefs.getBool('codeaw.liveActivity.details') ?? true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'token' && call.arguments is Map) {
        await _register(Map<String, dynamic>.from(call.arguments as Map));
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
    try {
      final info = await _call('status', null) as Map;
      supported = info['supported'] == true;
      authorized = info['authorized'] == true;
    } catch (_) {
      error = '無法啟用即時動態，請確認 iOS 版本與簽名保留 Widget extension';
    }
    _changed();
  }

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
    if (known != null) accept(known);
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
    if (!supported || client == null || !client.isOnline) return;
    try {
      final info = await client.request('_codeaw/live_activity/info') as Map;
      if (generation != _generation || _disposed) return;
      remoteEnabled = info['enabled'] == true;
      remoteReady = info['ready'] == true;
      remoteDetails = info['includeDetails'] == true;
      error = info['error'] as String?;
      final native = await _call('status', null) as Map;
      if (generation != _generation || _disposed) return;
      authorized = native['authorized'] == true;
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
      final list = await client.request('_codeaw/activity/list') as Map;
      if (generation != _generation || _disposed) return;
      for (final raw
          in (list['activities'] as List? ?? const []).whereType<Map>()) {
        accept(Map<String, dynamic>.from(raw));
      }
      _changed();
    } catch (_) {
      // An older bridge still works for chat; explain the feature's prerequisite.
      if (generation == _generation) {
        error = '即時動態需要更新版 bridge；重連後會再嘗試';
        _changed();
      }
    }
  }

  void accept(Map<String, dynamic> snapshot) {
    final id = snapshot['sessionId'];
    if (id is! String) return;
    _snapshots[id] = snapshot;
    _scheduleHeartbeat();
    if (!supported || !enabled || !_followed.contains(id)) return;
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
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'usePush': remoteReady,
    };
    _serial = _serial.then((_) async {
      if (_disposed || generation != _generation || !enabled) return;
      try {
        final result = await _call('sync', params) as Map?;
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

  void _scheduleHeartbeat() {
    final running =
        supported &&
        enabled &&
        _snapshots.entries.any(
          (entry) =>
              _followed.contains(entry.key) &&
              entry.value['work'] is Map &&
              entry.value['state'] != 'idle' &&
              entry.value['deleted'] != true,
        );
    if (!running) {
      _heartbeat?.cancel();
      _heartbeat = null;
    } else {
      _heartbeat ??= Timer.periodic(const Duration(seconds: 60), (_) {
        if (foreground && (_client?.isOnline ?? false)) unawaited(refresh());
      });
    }
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

  Future<void> configure({bool? enabled, bool? showDetails}) async {
    this.enabled = enabled ?? this.enabled;
    this.showDetails = showDetails ?? this.showDetails;
    _scheduleHeartbeat();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('codeaw.liveActivity.enabled', this.enabled);
    await prefs.setBool('codeaw.liveActivity.details', this.showDetails);
    if (!this.enabled) {
      for (final id in _tokens.keys.toList()) {
        await _unregister(id);
      }
      _tokens.clear();
      _registered.clear();
      if (supported) await _call('endAll', {'hostKey': _hostKey});
    } else {
      for (final token in _tokens.values.toList()) {
        await _register(token);
      }
      for (final snapshot in _snapshots.values.toList()) {
        accept(snapshot);
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
    if (supported && key != null) {
      _serial = _serial.then((_) async {
        try {
          await _call('endAll', {'hostKey': key});
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
    _tokens.clear();
    _registered.clear();
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
    super.dispose();
  }
}
