import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'bridge_client.dart';
import 'models.dart';
import 'session_controller.dart';
import 'sessions_model.dart';
import 'timeline.dart';

/// What the system offers for live progress on this device.
class LiveActivitySupport {
  const LiveActivitySupport({this.available = false, this.allowed = false, this.promoted});

  factory LiveActivitySupport.fromJson(Map<Object?, Object?> j) =>
      LiveActivitySupport(available: j['available'] == true, allowed: j['allowed'] == true, promoted: j['promoted'] as bool?);

  /// Android, or iOS 16.2 and later.
  final bool available;

  /// Notifications (Android) or Live Activities (iOS) are allowed in system settings.
  final bool allowed;

  /// Android 16 and later: whether the notification may be promoted to a Live Update.
  final bool? promoted;
}

/// The native side: a foreground service with a progress notification (a Live Update on
/// Android 16+), or an iOS Live Activity. Neither may be started from the background, so
/// native code starts it from the armed content as the app leaves the foreground.
class LiveActivityChannel {
  const LiveActivityChannel();

  static const _channel = MethodChannel('codeaw/live_activity');

  bool get platformSupported => !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  Future<LiveActivitySupport> support() async {
    final r = await _channel.invokeMapMethod<Object?, Object?>('support');
    return r == null ? const LiveActivitySupport() : LiveActivitySupport.fromJson(r);
  }

  /// Arms [content] while the app is visible and updates what is shown while it is not;
  /// `null` disarms and removes it.
  Future<void> show(Map<String, Object?>? content) => _channel.invokeMethod<void>('show', content);

  /// The system page where notifications, Live Updates or Live Activities are allowed.
  Future<void> openSettings() => _channel.invokeMethod<void>('openSettings');
}

/// Mirrors one running conversation into the system's live progress UI while the app is in
/// the background: a notification that Android 16 promotes to a Live Update, or an iOS Live
/// Activity on the Lock Screen and in the Dynamic Island.
///
/// The conversation is the one on screen when the app is left, or else the only one running.
/// It is followed until its turn, and anything queued behind it, is over or the app comes
/// back; no other conversation is picked up in the meantime.
class LiveActivityTracker extends ChangeNotifier {
  LiveActivityTracker({this.channel = const LiveActivityChannel()});

  final LiveActivityChannel channel;
  bool enabled = false;
  LiveActivitySupport support = const LiveActivitySupport();

  static const _prefsKey = 'codeaw.liveActivity.enabled';
  static const _minInterval = Duration(seconds: 1);
  // The bridge reports idle for a moment before it starts the next queued prompt.
  static const _queueGrace = Duration(seconds: 10);

  BridgeClient? _client;
  SessionsModel? _sessions;
  SessionHub? _hub;
  StreamSubscription<SessionMessage>? _messages;
  SessionController? _watched;
  String? _target;
  String? _viewing;
  bool _visible = true;
  String? _tracked;
  Timer? _queueTimer;
  bool _queueExpired = false;
  Map<String, Object?>? _pending;
  String? _shown;
  Timer? _cooldown;
  bool _disposed = false;

  bool get available => channel.platformSupported && support.available;

  Future<void> load() async {
    if (!channel.platformSupported) return;
    try {
      enabled = (await SharedPreferences.getInstance()).getBool(_prefsKey) ?? false;
    } catch (_) {}
    try {
      // Nothing armed by an earlier run of the engine.
      await channel.show(null);
    } catch (_) {}
    await refreshSupport();
  }

  Future<void> refreshSupport() async {
    if (!channel.platformSupported) return;
    try {
      final next = await channel.support();
      if (_disposed) return;
      support = next;
      notifyListeners();
      _sync();
    } catch (_) {}
  }

  Future<void> setEnabled(bool value) async {
    if (enabled == value) return;
    enabled = value;
    notifyListeners();
    _sync();
    try {
      await (await SharedPreferences.getInstance()).setBool(_prefsKey, value);
    } catch (_) {}
  }

  void bind(BridgeClient client, SessionsModel sessions, SessionHub hub) {
    unbind();
    _client = client..addListener(_sync);
    _sessions = sessions..addListener(_sync);
    _hub = hub;
    // The conversation may be opened on this device after it became the target.
    _messages = client.messages.listen((m) {
      if (_watched == null && m.sessionId == _target && hub.peek(_target!) != null) _sync();
    });
    _sync();
  }

  void unbind() {
    _client?.removeListener(_sync);
    _sessions?.removeListener(_sync);
    _messages?.cancel();
    _messages = null;
    _client = null;
    _sessions = null;
    _hub = null;
    _tracked = null;
    _sync();
  }

  /// The conversation on screen, if any.
  set viewing(String? sessionId) {
    if (_viewing == sessionId) return;
    _viewing = sessionId;
    _sync();
  }

  /// Whether the app is on screen; inactive counts (a system dialog, Control Center).
  set visible(bool value) {
    if (_visible == value) return;
    _visible = value;
    _tracked = value ? null : _pick();
    _resetQueue();
    _sync();
    // Live Activities or Live Updates may have been switched in Settings meanwhile.
    if (value) unawaited(refreshSupport());
  }

  void _sync() {
    if (_disposed) return;
    var id = enabled && available ? (_visible ? _pick() : _tracked) : null;
    if (id != null) {
      if (_running(id)) {
        _resetQueue();
      } else if (!_startingNext(id)) {
        id = null;
      }
    }
    if (id == null && !_visible) _tracked = null;
    _target = id;
    _watch(id);
    _send(id == null ? null : _content(id));
  }

  /// The conversation on screen if it is running, otherwise the only running one.
  String? _pick() {
    final viewing = _viewing;
    if (viewing != null && _running(viewing)) return viewing;
    String? only;
    for (final s in _sessions?.sessions ?? const <SessionSummary>[]) {
      if (!_running(s.id)) continue;
      if (only != null) return null;
      only = s.id;
    }
    return only;
  }

  ({String state, int queued}) _status(String id) {
    final c = _hub?.peek(id);
    if (c != null && c.attached) return (state: c.timeline.state, queued: c.timeline.queued);
    final s = _sessions?.byId(id);
    return (state: s?.state ?? c?.timeline.state ?? 'idle', queued: s?.queued ?? 0);
  }

  bool _running(String id) => switch (_status(id).state) {
        'running' || 'requires_action' => true,
        _ => false,
      };

  /// Idle with prompts still queued. Unless something holds the queue, this only lasts
  /// until the bridge starts the next one.
  bool _startingNext(String id) {
    if (_status(id).queued == 0 || _queueExpired) return false;
    _queueTimer ??= Timer(_queueGrace, () {
      _queueExpired = true;
      _sync();
    });
    return true;
  }

  void _resetQueue() {
    _queueTimer?.cancel();
    _queueTimer = null;
    _queueExpired = false;
  }

  /// Follows the open controller of [id] for its activity, plan and pending requests.
  void _watch(String? id) {
    final c = id == null ? null : _hub?.peek(id);
    if (identical(c, _watched)) return;
    _watched?.removeListener(_sync);
    _watched?.timeline.removeListener(_sync);
    _watched = c;
    c?.addListener(_sync);
    c?.timeline.addListener(_sync);
  }

  Map<String, Object?> _content(String id) {
    final c = _hub?.peek(id);
    final timeline = c?.timeline;
    final summary = _sessions?.byId(id);
    final agentId = summary?.agentId ?? id.split(':').first;
    final agent = _client?.agent(agentId)?.name ?? agentId;
    final title = _text(timeline?.title) ?? _text(summary?.title) ?? _text(folderName(summary?.cwd ?? c?.cwd ?? '')) ?? agent;
    final request = c?.pending.values.firstOrNull;
    final (phase, detail) = _client?.isOnline != true
        ? ('offline', '連線中斷，重新連線中…')
        : switch (_status(id).state) {
            'requires_action' => ('approval', request == null ? '需要你的批准' : '${request.isPermission ? '需要你的批准' : '需要你的回覆'}：${request.title}'),
            'running' => ('running', _doing(timeline)),
            _ => ('running', '準備處理下一則排隊訊息…'),
          };
    return {
      'sessionId': id,
      'link': 'codeaw://session/${Uri.encodeComponent(id)}',
      'agent': agent,
      'title': _clip(title, 100),
      'phase': phase,
      'detail': _clip(detail, 200),
      'startedAt': timeline?.turnStartedAt?.millisecondsSinceEpoch,
      // ACP plan entry statuses: pending, in_progress, completed.
      'steps': [for (final e in timeline?.plan ?? const <Map<String, dynamic>>[]) '${e['status'] ?? 'pending'}'],
    };
  }

  /// The working indicator's wording, with the tool's own title when there is one.
  static String _doing(Timeline? t) {
    final tool = t?.activeTool;
    return switch (t?.activity) {
      null => '執行中…',
      TurnActivity.thinking => '思考中…',
      TurnActivity.responding => '回覆中…',
      TurnActivity.tool when _text(tool?.title) != null => _text(tool!.displayTitle)!,
      TurnActivity.tool when tool?.mcp != null => '使用 MCP 工具中…',
      TurnActivity.tool => switch (tool?.kind) {
          'read' => '讀取檔案中…',
          'edit' => '修改檔案中…',
          'execute' => '執行指令中…',
          'search' => '搜尋中…',
          'fetch' => '取得資料中…',
          'think' => '思考中…',
          _ => '使用工具中…',
        },
    };
  }

  static String? _text(String? s) {
    final t = s?.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t == null || t.isEmpty ? null : t;
  }

  static String _clip(String s, int max) => s.runes.length <= max ? s : '${String.fromCharCodes(s.runes.take(max - 1))}…';

  /// Sends at most one update per [_minInterval]; removal is sent right away.
  void _send(Map<String, Object?>? content) {
    _pending = content;
    if (content == null || _cooldown == null) _flush();
  }

  void _flush() {
    final content = _pending;
    final key = content == null ? null : jsonEncode(content);
    if (key == _shown) return;
    _shown = key;
    unawaited(channel.show(content).catchError((Object _) {}));
    _cooldown?.cancel();
    _cooldown = Timer(_minInterval, () {
      _cooldown = null;
      _flush();
    });
  }

  @override
  void dispose() {
    unbind();
    _disposed = true;
    _queueTimer?.cancel();
    _cooldown?.cancel();
    super.dispose();
  }
}
