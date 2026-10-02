import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import '../acp/jsonrpc.dart';
import 'bridge_client.dart';

/// Retains the screen and shell identity when navigating away and back.
class TerminalHub {
  TerminalHub(this.client);
  final BridgeClient client;
  final _controllers = <String, ShellController>{};

  ShellController open(String cwd) => _controllers.putIfAbsent(cwd, () => ShellController(client, cwd));

  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    _controllers.clear();
  }
}

class ShellController extends ChangeNotifier {
  ShellController(this.client, this.cwd) {
    _resetScreen();
    _events = client.terminalEvents.listen(_onEvent);
    _connected = client.connected.listen((_) {
      if (_active) unawaited(attach());
    });
    client.addListener(_onConnection);
  }

  final BridgeClient client;
  final String cwd;
  late Terminal terminal;
  String? terminalId;
  String? shell;
  String? error;
  int lastSeq = 0;
  int? exitCode;
  bool loading = false;
  bool attached = false;
  bool exited = false;
  bool _active = false;
  bool _disposed = false;
  int _cols = 80;
  int _rows = 24;
  int _generation = 0;
  Timer? _resizeTimer;
  late final StreamSubscription<Map<String, dynamic>> _events;
  late final StreamSubscription<void> _connected;
  final _buffered = <Map<String, dynamic>>[];
  Future<void> _writes = Future.value();

  bool get canInput => attached && client.isOnline && !loading && !exited;

  void _resetScreen() {
    terminal = Terminal(maxLines: 5000)
      ..onOutput = (data) {
        unawaited(write(data));
      }
      ..onResize = (cols, rows, _, _) {
        _cols = cols.clamp(2, 500);
        _rows = rows.clamp(2, 500);
        _resizeTimer?.cancel();
        _resizeTimer = Timer(const Duration(milliseconds: 100), () {
          if (canInput) unawaited(_resize());
        });
      };
    terminal.resize(_cols, _rows);
  }

  void _onConnection() {
    if (!client.isOnline) attached = false;
    _notify();
  }

  Future<void> attach() async {
    _active = true;
    if (!client.isOnline || loading || _disposed) return;
    final generation = ++_generation;
    loading = true;
    error = null;
    _buffered.clear();
    _notify();
    try {
      final r =
          await client.request('_codeaw/terminal/open', {
                'cwd': cwd,
                'terminalId': ?terminalId,
                'afterSeq': lastSeq,
                'cols': _cols,
                'rows': _rows,
              })
              as Map<String, dynamic>;
      if (_disposed || generation != _generation) return;
      terminalId = r['terminalId'] as String;
      if (!_active) {
        await client.request('_codeaw/terminal/detach', {'terminalId': terminalId});
        return;
      }
      shell = r['shell'] as String?;
      if (r['full'] == true) {
        lastSeq = 0;
        _resetScreen();
      }
      exited = r['exited'] == true;
      exitCode = (r['exitCode'] as num?)?.toInt();
      attached = true;
      loading = false;
      for (final e in (r['events'] as List? ?? const []).whereType<Map<String, dynamic>>()) {
        _apply(e);
      }
      for (final e in _buffered) {
        if (e['terminalId'] == terminalId) _apply(e);
      }
      _buffered.clear();
    } catch (e) {
      if (!_disposed && generation == _generation) {
        attached = false;
        error = e is RpcError && e.code == -32601
            ? '請更新電腦端 bridge 以使用終端機'
            : e is RpcError
            ? e.detail
            : '$e';
      }
    } finally {
      if (!_disposed && generation == _generation) {
        loading = false;
        _notify();
      }
    }
  }

  void _onEvent(Map<String, dynamic> e) {
    if (!_active) return;
    if (loading) {
      _buffered.add(e);
    } else if (e['terminalId'] == terminalId) {
      _apply(e);
    }
  }

  void _apply(Map<String, dynamic> e) {
    final seq = (e['seq'] as num?)?.toInt() ?? 0;
    if (seq <= lastSeq) return;
    lastSeq = seq;
    if (e['type'] == 'data') terminal.write(e['data'] as String? ?? '');
    if (e['type'] == 'exit') {
      exited = true;
      exitCode = (e['exitCode'] as num?)?.toInt();
      _notify();
    }
  }

  Future<void> write(String data) {
    if (!canInput || data.isEmpty) return Future.value();
    final id = terminalId;
    final generation = _generation;
    _writes = _writes.then((_) async {
      if (!canInput || id != terminalId || generation != _generation) return;
      try {
        await client.request('_codeaw/terminal/write', {'terminalId': id, 'data': data});
      } catch (e) {
        if (!_disposed && client.isOnline) {
          error = e is RpcError ? e.detail : '$e';
          _notify();
        }
      }
    });
    return _writes;
  }

  Future<void> _resize() async {
    try {
      await client.request('_codeaw/terminal/resize', {'terminalId': terminalId, 'cols': _cols, 'rows': _rows});
    } catch (_) {
      /* A reconnect sends the current dimensions again. */
    }
  }

  Future<void> restart() async {
    if (loading || !client.isOnline) return;
    await close();
    if (_disposed || terminalId != null || error != null) return;
    lastSeq = 0;
    exited = false;
    exitCode = null;
    _resetScreen();
    await attach();
  }

  Future<void> close() async {
    if (loading || !client.isOnline) return;
    loading = true;
    error = null;
    _notify();
    try {
      if (terminalId != null) {
        await client.request('_codeaw/terminal/close', {'terminalId': terminalId});
      }
    } on RpcError catch (e) {
      if (!e.detail.contains('Terminal not found')) {
        error = e.detail;
        return;
      }
    } finally {
      loading = false;
      _notify();
    }
    if (_disposed) return;
    terminalId = null;
    _active = false;
    attached = false;
    exited = true;
    exitCode = null;
    _notify();
  }

  void detach() {
    _active = false;
    attached = false;
    _resizeTimer?.cancel();
    if (client.isOnline && terminalId != null) {
      unawaited(client.request('_codeaw/terminal/detach', {'terminalId': terminalId}).catchError((Object _) => null));
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    detach();
    _disposed = true;
    _events.cancel();
    _connected.cancel();
    client.removeListener(_onConnection);
    super.dispose();
  }
}
