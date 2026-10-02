import 'dart:async';
import 'dart:convert';

/// A JSON-RPC error response, or a local failure surfaced the same way.
class RpcError implements Exception {
  RpcError(this.code, this.message, [this.data]);

  final int code;
  final String message;
  final Object? data;

  static const connectionClosed = -32099;
  static const requestCancelled = -32800;

  /// Human-readable message including the agent's details when present.
  String get detail {
    final d = data;
    if (d is Map && d['details'] is String && !message.contains(d['details'] as String)) {
      return '$message: ${d['details']}';
    }
    if (d is Map && d['message'] is String && !message.contains(d['message'] as String)) {
      return '$message: ${d['message']}';
    }
    return message;
  }

  @override
  String toString() => 'RpcError($code): $detail';
}

/// Lets a server→client request be withdrawn (`$/cancel_request`).
class CancelToken {
  final _completer = Completer<void>();
  bool get isCancelled => _completer.isCompleted;
  Future<void> get whenCancelled => _completer.future;
  void cancel() {
    if (!_completer.isCompleted) _completer.complete();
  }
}

typedef RequestHandler = Future<Object?> Function(String method, Map<String, dynamic> params, CancelToken token);
typedef NotificationHandler = void Function(String method, Map<String, dynamic> params);

/// Bidirectional JSON-RPC 2.0 over any text message transport (one message per frame).
class JsonRpcPeer {
  JsonRpcPeer({required void Function(String) send, required this.onRequest, required this.onNotification})
      : _send = send;

  final void Function(String) _send;
  final RequestHandler onRequest;
  final NotificationHandler onNotification;

  int _nextId = 1;
  bool _closed = false;
  final _pending = <Object, Completer<Object?>>{};
  final _incoming = <Object, CancelToken>{};

  bool get isClosed => _closed;

  Future<Object?> request(String method, [Map<String, dynamic>? params]) {
    if (_closed) return Future.error(RpcError(RpcError.connectionClosed, 'Not connected'));
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _write({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params ?? const {}});
    return completer.future;
  }

  void notify(String method, [Map<String, dynamic>? params]) {
    if (_closed) return;
    _write({'jsonrpc': '2.0', 'method': method, 'params': params ?? const {}});
  }

  void _write(Map<String, Object?> message) => _send(jsonEncode(message));

  /// Feed one received text frame.
  void handle(String text) {
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return;
    }
    if (decoded is List) {
      for (final m in decoded) {
        if (m is Map<String, dynamic>) _handleMessage(m);
      }
    } else if (decoded is Map<String, dynamic>) {
      _handleMessage(decoded);
    }
  }

  void _handleMessage(Map<String, dynamic> m) {
    final method = m['method'];
    final id = m['id'];
    if (method is String) {
      final params = m['params'] is Map<String, dynamic> ? m['params'] as Map<String, dynamic> : <String, dynamic>{};
      if (id == null) {
        if (method == r'$/cancel_request') {
          _incoming.remove(params['requestId'])?.cancel();
        } else {
          onNotification(method, params);
        }
      } else {
        _serve(id as Object, method, params);
      }
      return;
    }
    if (id != null) {
      final completer = _pending.remove(id);
      if (completer == null) return;
      final error = m['error'];
      if (error is Map) {
        completer.completeError(RpcError((error['code'] as num?)?.toInt() ?? -32603, '${error['message'] ?? 'Error'}', error['data']));
      } else {
        completer.complete(m['result']);
      }
    }
  }

  Future<void> _serve(Object id, String method, Map<String, dynamic> params) async {
    final token = CancelToken();
    _incoming[id] = token;
    try {
      final result = await onRequest(method, params, token);
      if (_incoming.remove(id) == null && token.isCancelled) {
        // Withdrawn: the answer is still sent (harmless), the peer ignores it.
      }
      if (!_closed) _write({'jsonrpc': '2.0', 'id': id, 'result': result ?? const {}});
    } on RpcError catch (e) {
      _incoming.remove(id);
      if (!_closed) _write({'jsonrpc': '2.0', 'id': id, 'error': {'code': e.code, 'message': e.message, if (e.data != null) 'data': e.data}});
    } catch (e) {
      _incoming.remove(id);
      if (!_closed) _write({'jsonrpc': '2.0', 'id': id, 'error': {'code': -32603, 'message': '$e'}});
    }
  }

  /// Fails every outstanding request and withdraws every incoming one.
  void close() {
    if (_closed) return;
    _closed = true;
    for (final c in _pending.values) {
      c.completeError(RpcError(RpcError.connectionClosed, 'Connection closed'));
    }
    _pending.clear();
    for (final t in _incoming.values) {
      t.cancel();
    }
    _incoming.clear();
  }
}
