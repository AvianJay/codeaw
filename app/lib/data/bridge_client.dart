import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:file_selector/file_selector.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../acp/jsonrpc.dart';
import 'bridge_socket.dart';
import 'bridge_frame.dart';
import 'host.dart';
import 'models.dart';
import 'upload_progress.dart';
import 'file_download.dart';
import 'file_download_web.dart'
    if (dart.library.io) 'file_download_io.dart'
    as file_download;
import 'upload_transport_web.dart'
    if (dart.library.io) 'upload_transport_io.dart'
    as upload_transport;

export 'upload_progress.dart';

enum ConnStatus { offline, connecting, online }

/// A message addressed to one session (`session/update`, `_codeaw/event`, `_codeaw/replay`).
class SessionMessage {
  SessionMessage(this.method, this.params);
  final String method;
  final Map<String, dynamic> params;
  String get sessionId => params['sessionId'] as String? ?? '';
}

typedef ServerRequestHandler =
    Future<Object?> Function(
      String method,
      Map<String, dynamic> params,
      CancelToken token,
    );

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
  bool supportsProjectless = false;

  /// The bridge can branch a chat from an edited, already sent message.
  bool supportsPromptEditing = false;
  bool supportsFileArchives = false;

  // Synchronous on purpose: a replayed entry must reach its SessionController before the
  // `session/load` response does, or the response's lastSeq would mark it as a duplicate.
  final _messages = StreamController<SessionMessage>.broadcast(sync: true);
  final _activity = StreamController<Map<String, dynamic>>.broadcast(
    sync: true,
  );
  final _connected = StreamController<void>.broadcast();
  final _terminalEvents = StreamController<Map<String, dynamic>>.broadcast(
    sync: true,
  );

  /// Updates/events/replays for sessions.
  Stream<SessionMessage> get messages => _messages.stream;

  /// `_codeaw/activity`: state of every session, attached or not.
  Stream<Map<String, dynamic>> get activity => _activity.stream;

  /// Fires after every successful (re)connection + initialize.
  Stream<void> get connected => _connected.stream;
  Stream<Map<String, dynamic>> get terminalEvents => _terminalEvents.stream;

  ServerRequestHandler? onServerRequest;

  JsonRpcPeer? _peer;
  WebSocketChannel? _ws;
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
      final delay = Duration(
        milliseconds: [
          500,
          1000,
          2000,
          4000,
          8000,
          15000,
          30000,
        ][_attempt.clamp(0, 6)],
      );
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
        final ws = connectBridgeSocket(url, host.token);
        _ws = ws;
        final done = Completer<void>();
        final peer = JsonRpcPeer(
          send: ws.sink.add,
          onRequest: _handleRequest,
          onNotification: _handleNotification,
        );
        ws.stream.listen(
          (data) {
            try {
              peer.handle(decodeBridgeFrame(data));
            } catch (_) {
              peer.close();
              unawaited(ws.sink.close());
            }
          },
          onDone: () {
            if (!done.isCompleted) done.complete();
          },
          onError: (Object _) {
            if (!done.isCompleted) done.complete();
          },
          cancelOnError: true,
        );
        _peer = peer;
        await ws.ready.timeout(const Duration(seconds: 8));
        if (_disposed) {
          peer.close();
          await ws.sink.close();
          return null;
        }
        final init =
            await peer
                    .request('initialize', {
                      'protocolVersion': 1,
                      'clientCapabilities': {
                        'elicitation': {'form': {}},
                        'session': {
                          'configOptions': {'boolean': {}},
                        },
                      },
                      'clientInfo': {
                        'name': 'codeaw-app',
                        'title': 'codeaw',
                        'version': '0.1.0',
                      },
                    })
                    .timeout(const Duration(seconds: 10))
                as Map<String, dynamic>;
        if (_disposed) {
          peer.close();
          await ws.sink.close();
          return null;
        }
        final meta = (init['_meta'] as Map?)?['codeaw'] as Map?;
        agents = ((meta?['agents'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(AgentInfo.fromJson)
            .toList();
        bridgeHost = meta?['host'] as String?;
        supportsProjectless = meta?['projectless'] == true;
        supportsPromptEditing = meta?['editPrompts'] == true;
        supportsFileArchives = meta?['fileArchives'] == true;
        activeUrl = url;
        lastError = null;
        if (host.urls.first != url) {
          host = host.withUrls([url, ...host.urls.where((u) => u != url)]);
        }
        _setStatus(ConnStatus.online);
        peer.notify('_codeaw/client/state', {'foreground': _foreground});
        _connected.add(null);
        return (
          closed: done.future.then<void>((_) {
            peer.close();
            if (identical(_peer, peer)) {
              _peer = null;
              _ws = null;
              _setStatus(ConnStatus.offline);
            }
          }),
        );
      } catch (e) {
        if (_disposed) return null;
        errors.add(e is RpcError ? e.detail : '連線失敗（${e.runtimeType}）');
        _peer?.close();
        _peer = null;
        try {
          await _ws?.sink.close();
        } catch (_) {}
        _ws = null;
      }
    }
    lastError = errors.isEmpty ? null : errors.last;
    _setStatus(ConnStatus.offline);
    return null;
  }

  Future<Object?> _handleRequest(
    String method,
    Map<String, dynamic> params,
    CancelToken token,
  ) async {
    final handler = onServerRequest;
    if (handler == null) throw RpcError(-32601, 'Method not found: $method');
    return handler(method, params, token);
  }

  void _handleNotification(String method, Map<String, dynamic> params) {
    if (_disposed) return;
    switch (method) {
      case 'session/update' ||
          '_codeaw/event' ||
          '_codeaw/replay' ||
          '_codeaw/history/page':
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
    notify('_codeaw/client/state', {
      'foreground': value,
      'activeSessionId': ?activeSessionId,
    });
    if (value && status == ConnStatus.offline) reconnectNow();
  }

  /// Drops the socket as if the network went away (tests).
  @visibleForTesting
  Future<void> debugDropConnection() async => _ws?.sink.close();

  AgentInfo? agent(String id) {
    for (final a in agents) {
      if (a.id == id) return a;
    }
    return null;
  }

  /// Authenticated URL for bridge-hosted bytes (blobs, raw files).
  Uri httpUri(String path, [Map<String, String>? query]) => host.httpUri(
    activeUrl ?? host.urls.first,
    path,
    {...?query, if (kIsWeb) 'token': host.token},
  );

  Map<String, String> get authHeaders => {
    'Authorization': 'Bearer ${host.token}',
  };

  Future<DownloadedFile> downloadFile(
    String path, {
    required String name,
    DownloadProgress? onProgress,
    CancelToken? cancel,
  }) => file_download.fetchDownload(
    httpUri('/api/fs/raw', {'path': path, 'download': '1'}),
    authHeaders,
    name: name,
    onProgress: onProgress,
    cancel: cancel,
  );

  Future<DownloadedFile> downloadArchive(
    String path,
    List<String> paths, {
    required String name,
    DownloadProgress? onProgress,
    CancelToken? cancel,
  }) => file_download.fetchDownload(
    httpUri('/api/fs/archive'),
    authHeaders,
    name: name,
    body: jsonEncode({'path': path, 'paths': paths}),
    onProgress: onProgress,
    cancel: cancel,
  );

  Future<Map<String, dynamic>> uploadFile(
    String sessionId,
    String name,
    Uint8List bytes, {
    UploadProgressCallback? onProgress,
  }) async {
    if (bytes.length > maxUploadBytes) {
      throw const FormatException('檔案上限為 $uploadLimitLabel');
    }
    final response = await upload_transport.uploadBytes(
      httpUri('/api/uploads', {'sessionId': sessionId, 'name': name}),
      {...authHeaders, 'Content-Type': 'application/octet-stream'},
      bytes,
      onProgress: onProgress,
    );
    return _uploadedBlock(response);
  }

  Future<Map<String, dynamic>> uploadPickedFile(
    String sessionId,
    XFile file, {
    UploadProgressCallback? onProgress,
  }) async {
    final length = await file.length();
    if (length > maxUploadBytes) {
      throw const FormatException('檔案上限為 $uploadLimitLabel');
    }
    final response = await upload_transport.uploadFile(
      httpUri('/api/uploads', {'sessionId': sessionId, 'name': file.name}),
      {...authHeaders, 'Content-Type': 'application/octet-stream'},
      file,
      length,
      onProgress: onProgress,
    );
    return _uploadedBlock(response);
  }

  Map<String, dynamic> _uploadedBlock(http.Response response) {
    final result =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    if (response.statusCode != 201) {
      throw FormatException('${result['error'] ?? '檔案上傳失敗'}');
    }
    return Map<String, dynamic>.from(result['block'] as Map);
  }

  /// Stores a file on the bridge's computer for the agent to read.
  Future<UploadedFile> upload(
    String name,
    Uint8List bytes, {
    String? mimeType,
  }) async {
    if (!isOnline) throw const UploadException('尚未連上 bridge');
    if (bytes.length > maxUploadBytes) {
      throw const UploadException('檔案上限為 $uploadLimitLabel');
    }
    final http.Response response;
    try {
      response = await upload_transport.uploadBytes(
        httpUri('/api/uploads', {'name': name}),
        {
          ...authHeaders,
          'Content-Type': mimeType ?? 'application/octet-stream',
        },
        bytes,
      );
    } catch (_) {
      throw const UploadException('連線中斷，請再試一次');
    }
    Object? body;
    try {
      body = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {}
    if (response.statusCode == 200 && body is Map<String, dynamic>) {
      return UploadedFile.fromJson(body);
    }
    // Bridges from before uploads answer the route with 404.
    if (response.statusCode == 404) {
      throw const UploadException('電腦上的 bridge 版本較舊，請更新後再上傳檔案');
    }
    if (response.statusCode == 413) {
      throw const UploadException('檔案上限為 $uploadLimitLabel');
    }
    throw UploadException(
      body is Map && body['error'] is String
          ? body['error'] as String
          : 'HTTP ${response.statusCode}',
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _running = false;
    reconnectNow();
    _peer?.close();
    unawaited(_ws?.sink.close());
    _messages.close();
    _activity.close();
    _connected.close();
    _terminalEvents.close();
    super.dispose();
  }
}
