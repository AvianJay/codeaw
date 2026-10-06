import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../acp/jsonrpc.dart';
import 'bridge_client.dart';
import 'models.dart';
import 'history_cache.dart';
import 'timeline.dart';

/// A permission or elicitation request the bridge is waiting on.
class PendingRequest {
  PendingRequest(this.method, this.params, this.token);
  final String method;
  final Map<String, dynamic> params;
  final CancelToken token;
  final _answer = Completer<Object?>();

  String get requestId =>
      ((params['_meta'] as Map?)?['codeaw'] as Map?)?['requestId'] as String? ??
      '';
  bool get isPermission => method == 'session/request_permission';
  Map<String, dynamic> get toolCall =>
      params['toolCall'] as Map<String, dynamic>? ?? const {};
  List<Map<String, dynamic>> get options =>
      (params['options'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
  String get title => isPermission
      ? (toolCall['title'] as String? ?? '工具呼叫')
      : (params['message'] as String? ?? '需要你的回覆');
}

/// Everything about one open session: its timeline, connection to the bridge's log
/// (lastSeq/epoch for delta replay), open requests, and actions.
class SessionController extends ChangeNotifier {
  SessionController(
    this.client,
    this.sessionId, {
    String? cwd,
    HistoryCache? cache,
  }) : cwd = cwd ?? '',
       cache = cache ?? HistoryCache(client.host) {
    _connSub = client.connected.listen((_) {
      if (_wantAttached) unawaited(attach());
    });
    client.addListener(_onClientChange);
  }

  final BridgeClient client;
  final String sessionId;
  final HistoryCache cache;
  String cwd;

  /// Unsent text survives navigating between recently opened conversations.
  String draft = '';
  final _promptReceipts = <String, Completer<bool>>{};
  final timeline = Timeline();

  String get agentId => sessionId.split(':').first;
  AgentInfo? get agent => client.agent(agentId);

  int lastSeq = 0;
  String? epoch;
  bool loading = false;
  bool attached = false;
  bool desktopSync = false;
  bool desktopConnected = false;
  String? error;
  final pending = <String, PendingRequest>{};

  /// One-shot messages for the UI (snackbars): errors from prompts, config changes, …
  final _toasts = StreamController<String>.broadcast();
  Stream<String> get toasts => _toasts.stream;

  bool _wantAttached = false;
  bool _replayingFull = false;
  Timeline? _incoming;
  String? _incomingEpoch;
  Future<void>? _restoring;
  Future<void>? _attaching;
  Timer? _saveTimer;
  int _cacheRevision = 0;
  int _savedRevision = -1;
  Timer? _flushTimer;
  StreamSubscription<void>? _connSub;
  bool _disposed = false;

  bool get running => timeline.running;

  List<ConfigOption> get configOptions => (timeline.configOptions ?? const [])
      .map(ConfigOption.new)
      .where((o) => o.type == 'select' || o.type == 'boolean')
      .toList();

  void _onClientChange() {
    if (client.status != ConnStatus.online) _abortReplay();
    if (client.status != ConnStatus.online && attached) {
      attached = false;
      desktopConnected = false;
      // The bridge re-sends still-open requests after we re-attach.
      for (final p in pending.values) {
        p.token.cancel();
      }
      pending.clear();
      _notify();
    }
  }

  /// Attach to the session: full replay the first time, only missed entries afterwards.
  Future<void> attach() async {
    _wantAttached = true;
    final previous = _attaching;
    if (previous != null) return previous;
    final operation = _attach();
    _attaching = operation;
    try {
      await operation;
    } finally {
      if (identical(_attaching, operation)) _attaching = null;
    }
  }

  Future<void> restore() => _restoring ??= _restore();

  Future<void> _restore() async {
    final saved = await cache.read(sessionId);
    if (_disposed ||
        saved == null ||
        epoch != null ||
        lastSeq != 0 ||
        _replayingFull ||
        timeline.items.isNotEmpty) {
      return;
    }
    try {
      final restored = Timeline.fromSnapshot(
        saved['timeline'] as Map<String, dynamic>,
      );
      final cursor = (saved['lastSeq'] as num).toInt();
      final savedEpoch = saved['epoch'] as String;
      if (cursor < 0 || savedEpoch.isEmpty) return;
      for (final message in restored.items.whereType<MessageItem>()) {
        if (message.optimistic && message.receipt == 'sending') {
          message.receipt = 'unknown';
        }
      }
      timeline.replaceWith(restored);
      lastSeq = cursor;
      epoch = savedEpoch;
      if (cwd.isEmpty) cwd = saved['cwd'] as String? ?? '';
      desktopSync = saved['desktopSync'] == true;
      _savedRevision = _cacheRevision;
      _notify();
    } catch (_) {
      await cache.remove(sessionId);
    }
  }

  Future<void> _attach() async {
    await restore(); // Also restores while offline; never wait for the network to display history.
    if (_disposed || !_wantAttached || !client.isOnline) return;
    loading = true;
    error = null;
    _notify();
    try {
      final resp =
          await client.request('session/load', {
                'sessionId': sessionId,
                'cwd': cwd,
                'mcpServers': const [],
                '_meta': {
                  'codeaw': {
                    'lazyHistory': true,
                    if (epoch != null && lastSeq > 0) ...{
                      'afterSeq': lastSeq,
                      'epoch': epoch,
                    },
                  },
                },
              })
              as Map<String, dynamic>;
      if (_disposed || !_wantAttached) {
        client.notify('_codeaw/session/detach', {'sessionId': sessionId});
        return;
      }
      final m = (resp['_meta'] as Map?)?['codeaw'] as Map? ?? const {};
      desktopSync = m['connection'] == 'desktop';
      desktopConnected = m['desktopConnected'] == true;
      if (_replayingFull) {
        if (m['epoch'] == _incomingEpoch) _completeReplay(m);
      } else if (epoch == null || m['epoch'] == epoch) {
        lastSeq = max(lastSeq, (m['lastSeq'] as num?)?.toInt() ?? 0);
        epoch = m['epoch'] as String? ?? epoch;
      }
      if (m['epoch'] != null && m['epoch'] != epoch) {
        // A live history reset can finish while the original load response is in flight.
        attached = true;
        return;
      }
      timeline.finishReplay();
      if (m['cwd'] is String) cwd = m['cwd'] as String;
      if (m['title'] is String && timeline.title == null) {
        timeline.title = m['title'] as String;
      }
      if (resp['configOptions'] is List) {
        timeline.configOptions = (resp['configOptions'] as List)
            .whereType<Map<String, dynamic>>()
            .toList();
      }
      if (resp['modes'] is Map) {
        timeline.modes = Map<String, dynamic>.from(resp['modes'] as Map);
      }
      if (m['state'] is String) {
        timeline.setTurnState(
          m['state'] as String,
          startedAt: m['turnStartedAt'] as num?,
          promptId: m['turnPromptId'] as String?,
        );
      }
      timeline.queued = (m['queued'] as num?)?.toInt() ?? timeline.queued;
      attached = true;
      _scheduleSave();
    } on RpcError catch (e) {
      error = e.detail;
    } catch (e) {
      error = '$e';
    } finally {
      loading = false;
      if (!_disposed) {
        if (!attached) _abortReplay();
        timeline.flush();
      }
      _notify();
    }
  }

  /// Stop receiving live updates (screen closed). The log keeps going on the bridge.
  void detach() {
    _wantAttached = false;
    if (attached || loading) {
      client.notify('_codeaw/session/detach', {'sessionId': sessionId});
    }
    attached = false;
  }

  void onMessage(SessionMessage msg) {
    if (_disposed) return;
    if (msg.method == '_codeaw/replay') {
      if (msg.params['mode'] == 'full') {
        _incoming = Timeline();
        _incomingEpoch = msg.params['epoch'] as String?;
        _replayingFull = true;
      } else if (msg.params['mode'] == 'complete') {
        if (_replayingFull && msg.params['epoch'] == _incomingEpoch) {
          _completeReplay(msg.params);
        }
        _notify();
      } else {
        epoch = msg.params['epoch'] as String? ?? epoch;
      }
      return;
    }
    final seq =
        (((msg.params['_meta'] as Map?)?['codeaw'] as Map?)?['seq'] as num?)
            ?.toInt();
    if (!_replayingFull && seq != null) {
      if (seq <= lastSeq) return; // already seen (overlapping replay)
      lastSeq = seq;
    }
    if (msg.method == '_codeaw/event') {
      final event = msg.params['event'] as Map?;
      if (event?['type'] == 'prompt_receipt' &&
          ['received', 'read'].contains(event?['status'])) {
        final receipt = _promptReceipts[event?['promptId']];
        if (receipt != null && !receipt.isCompleted) receipt.complete(true);
      }
      if (event?['type'] == 'state' && event?['connection'] == 'desktop') {
        desktopSync = true;
        desktopConnected = event?['desktopConnected'] == true;
      }
    }
    (_incoming ?? timeline).apply(msg.method, msg.params);
    if (!_replayingFull) {
      _scheduleFlush();
      _scheduleSave();
    }
  }

  void _completeReplay(Map params) {
    final incoming = _incoming;
    if (incoming == null) return;
    timeline.replaceWith(incoming);
    epoch = _incomingEpoch;
    lastSeq = (params['lastSeq'] as num?)?.toInt() ?? 0;
    _incoming = null;
    _incomingEpoch = null;
    _replayingFull = false;
    _scheduleSave();
  }

  void _abortReplay() {
    _incoming = null;
    _incomingEpoch = null;
    _replayingFull = false;
  }

  void _scheduleSave() {
    _cacheRevision++;
    _saveTimer ??= Timer(const Duration(seconds: 2), () {
      _saveTimer = null;
      unawaited(persist());
    });
  }

  /// Background/eviction saves use the same complete cursor as the visible snapshot.
  Future<void> persist() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (_replayingFull || epoch == null || _savedRevision == _cacheRevision) {
      return;
    }
    _savedRevision = _cacheRevision;
    await cache.write(sessionId, {
      'epoch': epoch,
      'lastSeq': lastSeq,
      'cwd': cwd,
      'desktopSync': desktopSync,
      'timeline': timeline.toSnapshot(),
    });
  }

  Future<void> loadToolDetails(ToolItem tool) async {
    if (!tool.detailsDeferred || tool.loadingDetails) return;
    tool.loadingDetails = true;
    tool.detailError = null;
    tool.markDirty();
    tool.flush();
    final requestedEpoch = epoch;
    try {
      final response =
          await client.request('_codeaw/history/tool', {
                'sessionId': sessionId,
                'epoch': requestedEpoch,
                'toolCallId': tool.toolCallId,
              })
              as Map;
      if (_disposed ||
          epoch != requestedEpoch ||
          response['epoch'] != epoch ||
          !timeline.items.contains(tool)) {
        return;
      }
      final seq = (response['seq'] as num).toInt();
      if (seq < tool.activityRevision) throw StateError('工具仍在更新，請重試');
      tool.content = null;
      tool.rawOutput = null;
      tool.terminalOutput = '';
      tool.meta.clear();
      timeline.apply('session/update', {
        'update': {
          ...Map<String, dynamic>.from(response['update'] as Map),
          'sessionUpdate': 'tool_call',
        },
        '_meta': {
          'codeaw': {'seq': seq, 't': response['t']},
        },
      });
      tool.hydratedThroughSeq = seq;
      tool.deferredSeq = null;
      tool.deferredDiff = false;
      tool.deferredExitCode = null;
      timeline.flush();
      _scheduleSave();
    } catch (_) {
      if (!_disposed) {
        tool.detailError = client.isOnline ? '無法讀取完整輸出，點此重試' : '連上電腦後可讀取完整輸出';
      }
    } finally {
      tool.loadingDetails = false;
      if (!_disposed) {
        tool.markDirty();
        tool.flush();
      }
    }
  }

  void _scheduleFlush() {
    _flushTimer ??= Timer(const Duration(milliseconds: 50), () {
      _flushTimer = null;
      timeline.flush();
    });
  }

  Future<Object?> onServerRequest(
    String method,
    Map<String, dynamic> params,
    CancelToken token,
  ) async {
    final req = PendingRequest(method, params, token);
    final id = req.requestId.isEmpty
        ? '${DateTime.now().microsecondsSinceEpoch}'
        : req.requestId;
    pending[id] = req;
    _notify();
    try {
      return await Future.any([
        req._answer.future,
        token.whenCancelled.then((_) => null),
      ]);
    } finally {
      pending.remove(id);
      _notify();
    }
  }

  void answerPermission(PendingRequest req, String? optionId) {
    req._answer.complete({
      'outcome': optionId == null
          ? {'outcome': 'cancelled'}
          : {'outcome': 'selected', 'optionId': optionId},
    });
  }

  void answerElicitation(
    PendingRequest req,
    String action, [
    Map<String, dynamic>? content,
  ]) {
    req._answer.complete({
      'action': action,
      if (content != null && action == 'accept') 'content': content,
    });
  }

  /// Sends a prompt. While a turn runs it is steered into it (agents that support it) or queued.
  Future<bool> send(
    List<Map<String, dynamic>> blocks, {
    bool queue = false,
  }) async {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    final promptId =
        '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
    final receipt = Completer<bool>();
    _promptReceipts[promptId] = receipt;
    timeline.addPendingPrompt(promptId, blocks);
    final sent = () async {
      try {
        await client.request('session/prompt', {
          'sessionId': sessionId,
          'prompt': blocks,
          '_meta': {
            'codeaw': {
              'clientPromptId': promptId,
              if (queue) 'delivery': 'queue',
            },
          },
        });
        return true;
      } on RpcError catch (e) {
        if (_disposed) return true;
        if (e.code == RpcError.connectionClosed) {
          if (!receipt.isCompleted) {
            _toast('連線中斷，送出結果待確認；請先查看聊天紀錄，避免重複傳送');
            timeline.apply('_codeaw/event', {
              'event': {
                'type': 'prompt_receipt',
                'promptId': promptId,
                'status': 'unknown',
              },
            });
            timeline.flush();
          }
          // An interrupted turn RPC does not mean the bridge rejected the prompt.
          // Replay will reconcile it; never resurrect possibly accepted text.
          return true;
        }
        _toast(e.detail);
      } catch (e) {
        if (_disposed) return true;
        _toast('$e');
      }
      timeline.apply('_codeaw/event', {
        'event': {
          'type': 'prompt_receipt',
          'promptId': promptId,
          'status': 'failed',
        },
      });
      timeline.flush();
      return false;
    }();
    unawaited(sent.whenComplete(() => _promptReceipts.remove(promptId)));
    return Future.any([receipt.future, sent]);
  }

  void cancel() => client.notify('session/cancel', {'sessionId': sessionId});

  void reusePrompt(MessageItem prompt) {
    draft = draft.trim().isEmpty ? prompt.text : '$draft\n\n${prompt.text}';
    _notify();
    _toast('已填入原提示，可編輯後傳送');
  }

  Future<void> setConfig(ConfigOption option, Object value) async {
    try {
      final resp =
          await client.request('session/set_config_option', {
                'sessionId': sessionId,
                'configId': option.id,
                'value': value,
                if (value is bool) 'type': 'boolean',
              })
              as Map<String, dynamic>;
      if (resp['configOptions'] is List) {
        timeline.configOptions = (resp['configOptions'] as List)
            .whereType<Map<String, dynamic>>()
            .toList();
        timeline.flush();
        _notify();
      }
    } on RpcError catch (e) {
      _toast(e.detail);
    }
  }

  Future<bool> reimport() async {
    try {
      await client.request('_codeaw/session/reimport', {
        'sessionId': sessionId,
      });
      return true;
    } on RpcError catch (e) {
      _toast(e.detail);
      return false;
    }
  }

  Future<bool> closeOnAgent() async {
    try {
      await client.request('session/close', {'sessionId': sessionId});
      if (desktopSync) {
        attached = false;
        desktopConnected = false;
        _notify();
      }
      return true;
    } on RpcError catch (e) {
      _toast(e.detail);
      return false;
    }
  }

  void _toast(String message) {
    if (!_disposed) _toasts.add(message);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    unawaited(persist());
    _disposed = true;
    detach();
    _flushTimer?.cancel();
    _connSub?.cancel();
    client.removeListener(_onClientChange);
    for (final p in pending.values) {
      p.token.cancel();
    }
    _toasts.close();
    timeline.dispose();
    super.dispose();
  }
}

/// Routes bridge messages and requests to the open [SessionController]s and keeps a few
/// recently used ones alive so switching back is instant.
class SessionHub {
  SessionHub(this.client, {HistoryCache? cache})
    : cache = cache ?? HistoryCache(client.host) {
    _sub = client.messages.listen(
      (m) => _controllers[m.sessionId]?.onMessage(m),
    );
    client.onServerRequest = _onServerRequest;
    _activitySub = client.activity.listen((event) {
      if (event['deleted'] == true && event['sessionId'] is String) {
        final id = event['sessionId'] as String;
        _controllers.remove(id)?.dispose();
        _lru.remove(id);
        unawaited(this.cache.remove(id));
      }
    });
  }

  final BridgeClient client;
  final HistoryCache cache;
  final _controllers = <String, SessionController>{};
  final _lru = <String>[];
  late final StreamSubscription<SessionMessage> _sub;
  late final StreamSubscription<Map<String, dynamic>> _activitySub;
  static const _keep = 4;

  SessionController open(String sessionId, {String? cwd}) {
    var c = _controllers[sessionId];
    if (c == null) {
      c = SessionController(client, sessionId, cwd: cwd, cache: cache);
      _controllers[sessionId] = c;
      unawaited(c.attach());
    } else {
      if (cwd != null && c.cwd.isEmpty) c.cwd = cwd;
      if (!c.attached && !c.loading) unawaited(c.attach());
    }
    _lru
      ..remove(sessionId)
      ..add(sessionId);
    while (_lru.length > _keep) {
      final old = _lru.removeAt(0);
      _controllers.remove(old)?.dispose();
    }
    return c;
  }

  SessionController? peek(String sessionId) => _controllers[sessionId];

  /// A controller for a session just created through `session/new` (already attached).
  SessionController adopt(
    String sessionId,
    String cwd,
    Map<String, dynamic> newSessionResponse,
  ) {
    final c = SessionController(client, sessionId, cwd: cwd, cache: cache);
    final m =
        (newSessionResponse['_meta'] as Map?)?['codeaw'] as Map? ?? const {};
    c.lastSeq = (m['lastSeq'] as num?)?.toInt() ?? 0;
    c.epoch = m['epoch'] as String?;
    if (newSessionResponse['configOptions'] is List) {
      c.timeline.configOptions = (newSessionResponse['configOptions'] as List)
          .whereType<Map<String, dynamic>>()
          .toList();
    }
    c.attached = true;
    c._wantAttached = true;
    c._restoring = Future.value();
    c._scheduleSave();
    _controllers[sessionId] = c;
    _lru.add(sessionId);
    return c;
  }

  Future<Object?> _onServerRequest(
    String method,
    Map<String, dynamic> params,
    CancelToken token,
  ) async {
    final c = _controllers[params['sessionId']];
    if (c == null) {
      // Not open on this device: leave it to another device (or a later attach).
      await token.whenCancelled;
      return null;
    }
    return c.onServerRequest(method, params, token);
  }

  Future<void> persist() =>
      Future.wait(_controllers.values.map((c) => c.persist()));

  Future<void> clearCache() async {
    for (final c in _controllers.values) {
      c._saveTimer?.cancel();
      c._saveTimer = null;
      c._savedRevision = c._cacheRevision;
    }
    await cache.clear();
  }

  void dispose() {
    _sub.cancel();
    _activitySub.cancel();
    for (final c in _controllers.values) {
      c.dispose();
    }
    _controllers.clear();
  }
}
