import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../acp/jsonrpc.dart';
import 'host.dart';
import 'models.dart';

enum ConnStatus { offline, connecting, online }

/// A message addressed to one session (`session/update`, `_codeaw/event`, `_codeaw/replay`).
class SessionMessage {
  SessionMessage(this.method, this.params);
  final String method;
  final Map<String, dynamic> params;
  String get sessionId => params['sessionId'] as String? ?? '';
}

typedef ServerRequestHandler = Future<Object?> Function(String method, Map<String, dynamic> params, CancelToken token);

/// Keeps one WebSocket to the bridge alive: connects, initializes, reconnects with backoff,
/// and exposes typed helpers. Session state lives in [SessionController]s.
class BridgeClient extends ChangeNotifier {
  BridgeClient(this.host);

  HostConfig host;
  ConnStatus status = ConnStatus.offline;
  String? lastError;
  String? activeUrl;
  List<AgentInfo> agents = const [];
  String? bridgeHost;

  // Synchronous on purpose: a replayed entry must reach its SessionController before the
  // `session/load` response does, or the response's lastSeq would mark it as a duplicate.
  final _messages = StreamController<SessionMessage>.broadcast(sync: true);
  final _activity = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final _connected = StreamController<void>.broadcast();
  final _terminalEvents = StreamController<Map<String, dynamic>>.broadcast(sync: true);

  /// Updates/events/replays for sessions.
  Stream<SessionMessage> get messages => _messages.stream;

  /// `_codeaw/activity`: state of every session, attached or not.
  Stream<Map<String, dynamic>> get activity => _activity.stream;

  /// Fires after every successful (re)connection + initialize.
  Stream<void> get connected => _connected.stream;
  Stream<Map<String, dynamic>> get terminalEvents => _terminalEvents.stream;

  ServerRequestHandler? onServerRequest;

  JsonRpcPeer? _peer;
  WebSocket? _ws;
  bool _running = false;
  bool _disposed = false;
  bool _foreground = true;
  Completer<void>? _wake;
  int _attempt = 0;

  bool get isOnline => status == ConnStatus.online;

  void start() {
    if (_running) return;
    _running = true;
    unawaited(_loop());
  }

  /// Skip the backoff wait (app came to the foreground, network changed, user pulled to refresh).
  void reconnectNow() {
    _attempt = 0;
    if (_wake != null && !_wake!.isCompleted) _wake!.complete();
  }

  Future<void> _loop() async {
    while (!_disposed) {
      final conn = await _connectOnce();
      if (_disposed) break;
      if (conn != null) {
        // Connected and later dropped: retry quickly.
        await conn.closed;
        _attempt = 0;
        if (_disposed) break;
      }
      final delay = Duration(milliseconds: [500, 1000, 2000, 4000, 8000, 15000, 30000][_attempt.clamp(0, 6)]);
      _attempt++;
      _wake = Completer<void>();
      await Future.any([Future<void>.delayed(delay), _wake!.future]);
    }
  }

  /// Returns the live connection (whose `closed` completes when it drops), or null if connecting failed.
  Future<({Future<void> closed})?> _connectOnce() async {
    _setStatus(ConnStatus.connecting);
    final errors = <String>[];
    for (final url in host.urls) {
      try {
        final ws = await WebSocket.connect(url, headers: {'Authorization': 'Bearer ${host.token}'}).timeout(const Duration(seconds: 8));
        ws.pingInterval = const Duration(seconds: 15);
        final done = Completer<void>();
        final peer = JsonRpcPeer(
          send: (text) {
            if (ws.readyState == WebSocket.open) ws.add(text);
          },
          onRequest: _handleRequest,
          onNotification: _handleNotification,
        );
        ws.listen(
          (data) {
            if (data is String) peer.handle(data);
          },
          onDone: () {
            if (!done.isCompleted) done.complete();
          },
          onError: (Object _) {
            if (!done.isCompleted) done.complete();
          },
          cancelOnError: true,
        );
        _ws = ws;
        _peer = peer;
        final init = await peer.request('initialize', {
          'protocolVersion': 1,
          'clientCapabilities': {
            'elicitation': {'form': {}},
            'session': {
              'configOptions': {'boolean': {}},
            },
          },
          'clientInfo': {'name': 'codeaw-app', 'title': 'codeaw', 'version': '0.1.0'},
        }).timeout(const Duration(seconds: 10)) as Map<String, dynamic>;
        final meta = (init['_meta'] as Map?)?['codeaw'] as Map?;
        agents = ((meta?['agents'] as List?) ?? const []).whereType<Map<String, dynamic>>().map(AgentInfo.fromJson).toList();
        bridgeHost = meta?['host'] as String?;
        activeUrl = url;
        lastError = null;
        if (host.urls.first != url) host = host.withUrls([url, ...host.urls.where((u) => u != url)]);
        _setStatus(ConnStatus.online);
        peer.notify('_codeaw/client/state', {'foreground': _foreground});
        _connected.add(null);
        return (closed: done.future.then<void>((_) {
          peer.close();
          if (identical(_peer, peer)) {
            _peer = null;
            _ws = null;
            _setStatus(ConnStatus.offline);
          }
        }));
      } catch (e) {
        errors.add(e is RpcError ? e.detail : '$e');
        _peer?.close();
        _peer = null;
        try {
          await _ws?.close();
        } catch (_) {}
        _ws = null;
      }
    }
    lastError = errors.isEmpty ? null : errors.last;
    _setStatus(ConnStatus.offline);
    return null;
  }

  Future<Object?> _handleRequest(String method, Map<String, dynamic> params, CancelToken token) async {
    final handler = onServerRequest;
    if (handler == null) throw RpcError(-32601, 'Method not found: $method');
    return handler(method, params, token);
  }

  void _handleNotification(String method, Map<String, dynamic> params) {
    switch (method) {
      case 'session/update' || '_codeaw/event' || '_codeaw/replay':
        _messages.add(SessionMessage(method, params));
      case '_codeaw/activity':
        _activity.add(params);
      case '_codeaw/terminal/event':
        _terminalEvents.add(params);
    }
  }

  void _setStatus(ConnStatus s) {
    if (status == s) return;
    status = s;
    if (!_disposed) notifyListeners();
  }

  Future<dynamic> request(String method, [Map<String, dynamic>? params]) {
    final peer = _peer;
    if (peer == null || status != ConnStatus.online) {
      return Future.error(RpcError(RpcError.connectionClosed, '尚未連上 bridge'));
    }
    return peer.request(method, params);
  }

  void notify(String method, [Map<String, dynamic>? params]) {
    if (status == ConnStatus.online) _peer?.notify(method, params);
  }

  void setForeground(bool value, {String? activeSessionId}) {
    _foreground = value;
    notify('_codeaw/client/state', {'foreground': value, 'activeSessionId': ?activeSessionId});
    if (value && status == ConnStatus.offline) reconnectNow();
  }

  /// Drops the socket as if the network went away (tests).
  @visibleForTesting
  Future<void> debugDropConnection() async => _ws?.close();

  AgentInfo? agent(String id) {
    for (final a in agents) {
      if (a.id == id) return a;
    }
    return null;
  }

  /// Authenticated URL for bridge-hosted bytes (blobs, raw files).
  Uri httpUri(String path, [Map<String, String>? query]) => host.httpUri(activeUrl ?? host.urls.first, path, query);

  Map<String, String> get authHeaders => {'Authorization': 'Bearer ${host.token}'};

  @override
  void dispose() {
    _disposed = true;
    _running = false;
    reconnectNow();
    _peer?.close();
    unawaited(_ws?.close());
    _messages.close();
    _activity.close();
    _connected.close();
    _terminalEvents.close();
    super.dispose();
  }
}
