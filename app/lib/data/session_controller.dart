import 'dart:async';

import 'package:flutter/foundation.dart';

import '../acp/jsonrpc.dart';
import 'bridge_client.dart';
import 'models.dart';
import 'timeline.dart';

/// A permission or elicitation request the bridge is waiting on.
class PendingRequest {
  PendingRequest(this.method, this.params, this.token);
  final String method;
  final Map<String, dynamic> params;
  final CancelToken token;
  final _answer = Completer<Object?>();

  String get requestId => ((params['_meta'] as Map?)?['codeaw'] as Map?)?['requestId'] as String? ?? '';
  bool get isPermission => method == 'session/request_permission';
  Map<String, dynamic> get toolCall => params['toolCall'] as Map<String, dynamic>? ?? const {};
  List<Map<String, dynamic>> get options => (params['options'] as List? ?? const []).whereType<Map<String, dynamic>>().toList();
  String get title => isPermission ? (toolCall['title'] as String? ?? '工具呼叫') : (params['message'] as String? ?? '需要你的回覆');
}

/// Everything about one open session: its timeline, connection to the bridge's log
/// (lastSeq/epoch for delta replay), open requests, and actions.
class SessionController extends ChangeNotifier {
  SessionController(this.client, this.sessionId, {String? cwd}) : cwd = cwd ?? '' {
    _connSub = client.connected.listen((_) {
      if (_wantAttached) unawaited(attach());
    });
    client.addListener(_onClientChange);
  }

  final BridgeClient client;
  final String sessionId;
  String cwd;
  final timeline = Timeline();

  String get agentId => sessionId.split(':').first;
  AgentInfo? get agent => client.agent(agentId);

  int lastSeq = 0;
  String? epoch;
  bool loading = false;
  bool attached = false;
  String? error;
  final pending = <String, PendingRequest>{};

  /// One-shot messages for the UI (snackbars): errors from prompts, config changes, …
  final _toasts = StreamController<String>.broadcast();
  Stream<String> get toasts => _toasts.stream;

  bool _wantAttached = false;
  bool _replayingFull = false;
  Timer? _flushTimer;
  StreamSubscription<void>? _connSub;
  bool _disposed = false;

  bool get running => timeline.state == 'running' || timeline.state == 'requires_action';

  List<ConfigOption> get configOptions => (timeline.configOptions ?? const []).map(ConfigOption.new).where((o) => o.type == 'select' || o.type == 'boolean').toList();

  void _onClientChange() {
    if (client.status != ConnStatus.online && attached) {
      attached = false;
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
    if (!client.isOnline) return;
    loading = true;
    error = null;
    _notify();
    try {
      final resp = await client.request('session/load', {
        'sessionId': sessionId,
        'cwd': cwd,
        'mcpServers': const [],
        '_meta': {
          'codeaw': {if (epoch != null && lastSeq > 0) ...{'afterSeq': lastSeq, 'epoch': epoch}},
        },
      }) as Map<String, dynamic>;
      final m = (resp['_meta'] as Map?)?['codeaw'] as Map? ?? const {};
      _replayingFull = false;
      lastSeq = (m['lastSeq'] as num?)?.toInt() ?? lastSeq;
      epoch = m['epoch'] as String? ?? epoch;
      if (m['cwd'] is String) cwd = m['cwd'] as String;
      if (m['title'] is String && timeline.title == null) timeline.title = m['title'] as String;
      if (resp['configOptions'] is List) {
        timeline.configOptions = (resp['configOptions'] as List).whereType<Map<String, dynamic>>().toList();
      }
      if (resp['modes'] is Map) timeline.modes = Map<String, dynamic>.from(resp['modes'] as Map);
      if (m['state'] is String) timeline.state = m['state'] as String;
      timeline.queued = (m['queued'] as num?)?.toInt() ?? timeline.queued;
      attached = true;
    } on RpcError catch (e) {
      error = e.detail;
    } catch (e) {
      error = '$e';
    } finally {
      loading = false;
      timeline.flush();
      _notify();
    }
  }

  /// Stop receiving live updates (screen closed). The log keeps going on the bridge.
  void detach() {
    _wantAttached = false;
    if (attached) client.notify('_codeaw/session/detach', {'sessionId': sessionId});
    attached = false;
  }

  void onMessage(SessionMessage msg) {
    if (msg.method == '_codeaw/replay') {
      if (msg.params['mode'] == 'full') {
        timeline.clear();
        _replayingFull = true;
      }
      epoch = msg.params['epoch'] as String? ?? epoch;
      return;
    }
    final seq = (((msg.params['_meta'] as Map?)?['codeaw'] as Map?)?['seq'] as num?)?.toInt();
    if (!_replayingFull && seq != null) {
      if (seq <= lastSeq) return; // already seen (overlapping replay)
      lastSeq = seq;
    }
    timeline.apply(msg.method, msg.params);
    _scheduleFlush();
  }

  void _scheduleFlush() {
    _flushTimer ??= Timer(const Duration(milliseconds: 50), () {
      _flushTimer = null;
      timeline.flush();
    });
  }

  Future<Object?> onServerRequest(String method, Map<String, dynamic> params, CancelToken token) async {
    final req = PendingRequest(method, params, token);
    final id = req.requestId.isEmpty ? '${DateTime.now().microsecondsSinceEpoch}' : req.requestId;
    pending[id] = req;
    _notify();
    try {
      return await Future.any([req._answer.future, token.whenCancelled.then((_) => null)]);
    } finally {
      pending.remove(id);
      _notify();
    }
  }

  void answerPermission(PendingRequest req, String? optionId) {
    req._answer.complete({
      'outcome': optionId == null ? {'outcome': 'cancelled'} : {'outcome': 'selected', 'optionId': optionId},
    });
  }

  void answerElicitation(PendingRequest req, String action, [Map<String, dynamic>? content]) {
    req._answer.complete({'action': action, if (content != null && action == 'accept') 'content': content});
  }

  /// Sends a prompt. While a turn runs it is steered into it (agents that support it) or queued.
  Future<void> send(List<Map<String, dynamic>> blocks, {bool queue = false}) async {
    try {
      await client.request('session/prompt', {
        'sessionId': sessionId,
        'prompt': blocks,
        if (queue) '_meta': {'codeaw': {'delivery': 'queue'}},
      });
    } on RpcError catch (e) {
      if (e.code != RpcError.connectionClosed) _toast(e.detail);
    } catch (e) {
      _toast('$e');
    }
  }

  void cancel() => client.notify('session/cancel', {'sessionId': sessionId});

  Future<void> setConfig(ConfigOption option, Object value) async {
    try {
      final resp = await client.request('session/set_config_option', {
        'sessionId': sessionId,
        'configId': option.id,
        'value': value,
        if (value is bool) 'type': 'boolean',
      }) as Map<String, dynamic>;
      if (resp['configOptions'] is List) {
        timeline.configOptions = (resp['configOptions'] as List).whereType<Map<String, dynamic>>().toList();
        timeline.flush();
        _notify();
      }
    } on RpcError catch (e) {
      _toast(e.detail);
    }
  }

  Future<bool> reimport() async {
    try {
      await client.request('_codeaw/session/reimport', {'sessionId': sessionId});
      return true;
    } on RpcError catch (e) {
      _toast(e.detail);
      return false;
    }
  }

  Future<bool> closeOnAgent() async {
    try {
      await client.request('session/close', {'sessionId': sessionId});
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
  SessionHub(this.client) {
    _sub = client.messages.listen((m) => _controllers[m.sessionId]?.onMessage(m));
    client.onServerRequest = _onServerRequest;
  }

  final BridgeClient client;
  final _controllers = <String, SessionController>{};
  final _lru = <String>[];
  late final StreamSubscription<SessionMessage> _sub;
  static const _keep = 4;

  SessionController open(String sessionId, {String? cwd}) {
    var c = _controllers[sessionId];
    if (c == null) {
      c = SessionController(client, sessionId, cwd: cwd);
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
  SessionController adopt(String sessionId, String cwd, Map<String, dynamic> newSessionResponse) {
    final c = SessionController(client, sessionId, cwd: cwd);
    final m = (newSessionResponse['_meta'] as Map?)?['codeaw'] as Map? ?? const {};
    c.lastSeq = (m['lastSeq'] as num?)?.toInt() ?? 0;
    c.epoch = m['epoch'] as String?;
    if (newSessionResponse['configOptions'] is List) {
      c.timeline.configOptions = (newSessionResponse['configOptions'] as List).whereType<Map<String, dynamic>>().toList();
    }
    c.attached = true;
    c._wantAttached = true;
    _controllers[sessionId] = c;
    _lru.add(sessionId);
    return c;
  }

  Future<Object?> _onServerRequest(String method, Map<String, dynamic> params, CancelToken token) async {
    final c = _controllers[params['sessionId']];
    if (c == null) {
      // Not open on this device: leave it to another device (or a later attach).
      await token.whenCancelled;
      return null;
    }
    return c.onServerRequest(method, params, token);
  }

  void dispose() {
    _sub.cancel();
    for (final c in _controllers.values) {
      c.dispose();
    }
    _controllers.clear();
  }
}
