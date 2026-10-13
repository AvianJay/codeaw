import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import '../acp/jsonrpc.dart';
import 'bridge_client.dart';

/// The bridge owns the shells; this hub restores their tabs after a fresh launch.
class TerminalHub extends ChangeNotifier {
  TerminalHub(this.client) {
    _connection = client.connected.listen((_) {
      if (initialized) unawaited(refresh());
    });
  }
  final BridgeClient client;
  final _controllers = <ShellController>[];
  late final StreamSubscription<void> _connection;
  ShellController? active;
  bool initialized = false;
  bool loading = false;
  String? error;
  int maxTerminals = 8;
  bool _visible = false;
  bool _disposed = false;
  Future<void>? _refreshing;

  List<ShellController> get controllers => List.unmodifiable(_controllers);
  bool get canCreate =>
      client.isOnline &&
      initialized &&
      !loading &&
      error == null &&
      _controllers.length < maxTerminals;

  Future<void> show({String cwd = ''}) async {
    _visible = true;
    await refresh();
    if (_disposed || !_visible) return;
    if (cwd.isNotEmpty) {
      final existing = active?.cwd == cwd
          ? active
          : _controllers.where((c) => c.cwd == cwd).firstOrNull;
      if (existing != null) {
        select(existing);
      } else if (canCreate) {
        create(cwd);
      }
    } else if (active != null) {
      select(active!);
    }
  }

  Future<void> refresh() =>
      _refreshing ??= _refresh().whenComplete(() => _refreshing = null);

  Future<void> _refresh() async {
    if (_disposed || !client.isOnline) return;
    loading = true;
    error = null;
    notifyListeners();
    final knownIds = {for (final c in _controllers) c: c.terminalId};
    try {
      final result =
          await client.request('_codeaw/terminal/list') as Map<String, dynamic>;
      if (_disposed) return;
      final saved = (result['terminals'] as List? ?? const [])
          .whereType<Map<String, dynamic>>();
      final ids = <String>{};
      for (final item in saved) {
        final id = item['terminalId'] as String;
        ids.add(id);
        var c = _controllers
            .where(
              (c) =>
                  c.terminalId == id ||
                  (c.terminalId == null && c.creationId == item['creationId']),
            )
            .firstOrNull;
        if (c == null) {
          c = ShellController(
            client,
            item['cwd'] as String,
            terminalId: id,
            creationId: item['creationId'] as String?,
          );
          _add(c);
        }
        c.terminalId = id;
        c.shell = item['shell'] as String?;
        c.exited = item['exited'] == true;
        c.exitCode = (item['exitCode'] as num?)?.toInt();
      }
      for (final c in _controllers.toList()) {
        if (c.terminalId != null &&
            knownIds[c] == c.terminalId &&
            !ids.contains(c.terminalId)) {
          _controllers.remove(c);
          c.removeListener(_changed);
          c.dispose();
        }
      }
      if (!_controllers.contains(active)) {
        active =
            _controllers
                .where((c) => c.terminalId == result['activeTerminalId'])
                .firstOrNull ??
            _controllers.lastOrNull;
      }
      maxTerminals = (result['maxTerminals'] as num?)?.toInt() ?? 8;
      initialized = true;
      if (_visible && active != null) {
        unawaited(active!.attach());
      }
    } catch (e) {
      if (!_disposed) {
        error = e is RpcError && e.code == -32601
            ? '請更新電腦上的 bridge 以使用多終端機'
            : e is RpcError
            ? e.detail
            : '$e';
      }
    } finally {
      if (!_disposed) {
        loading = false;
        notifyListeners();
      }
    }
  }

  void _add(ShellController c) {
    _controllers.add(c);
    c.addListener(_changed);
  }

  ShellController? create(String cwd) {
    if (!canCreate) return null;
    final c = ShellController(client, cwd);
    _add(c);
    select(c);
    return c;
  }

  void select(ShellController c) {
    if (_disposed || !_controllers.contains(c)) return;
    if (active != c) active?.detach();
    active = c;
    _visible = true;
    notifyListeners();
    unawaited(c.attach());
  }

  Future<void> close(ShellController c) async {
    await c.close();
    if (_disposed ||
        !_controllers.contains(c) ||
        c.terminalId != null ||
        c.error != null ||
        c.loading) {
      return;
    }
    final index = _controllers.indexOf(c);
    _controllers.remove(c);
    c.removeListener(_changed);
    c.dispose();
    if (active == c) {
      active = _controllers.isEmpty
          ? null
          : _controllers[index.clamp(0, _controllers.length - 1)];
      if (_visible && active != null) unawaited(active!.attach());
    }
    notifyListeners();
  }

  void hide() {
    _visible = false;
    active?.detach();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _connection.cancel();
    for (final c in _controllers) {
      c.removeListener(_changed);
      c.dispose();
    }
    _controllers.clear();
    super.dispose();
  }
}

class ShellController extends ChangeNotifier {
  ShellController(this.client, this.cwd, {this.terminalId, String? creationId})
    : creationId = creationId ?? _newCreationId() {
    _resetScreen();
    _events = client.terminalEvents.listen(_onEvent);
    _connected = client.connected.listen((_) {
      if (_active) unawaited(attach());
    });
    client.addListener(_onConnection);
  }

  final BridgeClient client;
  final String cwd;
  final String creationId;
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

  static String _newCreationId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

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
    if (!client.isOnline || loading || attached || _disposed) return;
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
                if (terminalId == null) 'createNew': true,
                if (terminalId == null) 'creationId': creationId,
                'afterSeq': lastSeq,
                'cols': _cols,
                'rows': _rows,
              })
              as Map<String, dynamic>;
      if (_disposed || generation != _generation) return;
      terminalId = r['terminalId'] as String;
      if (!_active) {
        await client.request('_codeaw/terminal/detach', {
          'terminalId': terminalId,
        });
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
      for (final e
          in (r['events'] as List? ?? const [])
              .whereType<Map<String, dynamic>>()) {
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
        await client.request('_codeaw/terminal/write', {
          'terminalId': id,
          'data': data,
        });
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
      await client.request('_codeaw/terminal/resize', {
        'terminalId': terminalId,
        'cols': _cols,
        'rows': _rows,
      });
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
        await client.request('_codeaw/terminal/close', {
          'terminalId': terminalId,
        });
      }
    } catch (e) {
      if (e is! RpcError || !e.detail.contains('Terminal not found')) {
        error = e is RpcError ? e.detail : '$e';
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
      unawaited(
        client
            .request('_codeaw/terminal/detach', {'terminalId': terminalId})
            .catchError((Object _) => null),
      );
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
