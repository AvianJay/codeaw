import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart' as xterm;

import '../../app_state.dart';
import '../../data/bridge_client.dart';
import '../../data/models.dart';
import '../../data/terminal_controller.dart';
import '../common/adaptive.dart';
import '../common/widgets.dart';

class TerminalPage extends StatefulWidget {
  const TerminalPage({super.key, this.cwd = ''});
  final String cwd;

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  ShellController? _shell;
  final _focus = FocusNode();
  final _selection = xterm.TerminalController();
  List<Map<String, dynamic>> _roots = [];
  bool _loadingRoots = false;
  String? _error;
  late final BridgeClient _client;
  StreamSubscription<void>? _connection;

  @override
  void initState() {
    super.initState();
    _client = AppScope.read(context).client!;
    _connection = _client.connected.listen((_) {
      if (_shell == null) unawaited(_loadRoots());
    });
    if (widget.cwd.isNotEmpty) {
      _open(widget.cwd);
    } else {
      unawaited(_loadRoots());
    }
  }

  void _open(String cwd) {
    _focus.unfocus();
    _shell?.detach();
    _selection.clearSelection();
    final hub = AppScope.read(context).terminals;
    if (hub == null) return;
    _shell = hub.open(cwd);
    unawaited(_shell!.attach());
    setState(() {});
  }

  Future<void> _loadRoots() async {
    if (!_client.isOnline || _loadingRoots) return;
    setState(() {
      _loadingRoots = true;
      _error = null;
    });
    try {
      final r =
          await _client.request('_codeaw/workspaces/list')
              as Map<String, dynamic>;
      if (mounted) {
        setState(
          () => _roots = (r['roots'] as List? ?? const [])
              .whereType<Map<String, dynamic>>()
              .toList(),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loadingRoots = false);
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted || _shell?.canInput != true || data?.text == null) return;
    _shell!.terminal.paste(data!.text!);
    _focus.requestFocus();
  }

  void _copy() {
    final range = _selection.selection;
    if (range == null || _shell == null) return;
    unawaited(
      Clipboard.setData(
        ClipboardData(text: _shell!.terminal.buffer.getText(range)),
      ),
    );
    _selection.clearSelection();
  }

  @override
  void dispose() {
    _shell?.detach();
    _connection?.cancel();
    _focus.dispose();
    _selection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _shell;
    return ListenableBuilder(
      listenable: Listenable.merge([_client, ?c, _selection]),
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('終端機'),
              Text(
                c == null ? '選擇電腦上的工作目錄' : c.cwd,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5),
              ),
            ],
          ),
          actions: [
            if (c != null) ...[
              IconButton(
                tooltip: '複製選取文字',
                icon: const Icon(Icons.copy_outlined),
                onPressed: _selection.selection == null ? null : _copy,
              ),
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'restart') unawaited(c.restart());
                  if (v == 'close') unawaited(c.close());
                  if (v == 'clear') c.terminal.write('\x1b[2J\x1b[H\x1b[3J');
                  if (v == 'folder') {
                    c.detach();
                    setState(() => _shell = null);
                    unawaited(_loadRoots());
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'clear', child: Text('清除畫面')),
                  PopupMenuItem(
                    value: 'close',
                    enabled: _client.isOnline && !c.loading && !c.exited,
                    child: const Text('關閉終端機'),
                  ),
                  PopupMenuItem(
                    value: 'restart',
                    enabled: _client.isOnline && !c.loading,
                    child: const Text('關閉並重開 shell'),
                  ),
                  const PopupMenuItem(value: 'folder', child: Text('切換工作目錄')),
                ],
              ),
            ],
          ],
        ),
        body: Column(
          children: [
            const ConnectionBanner(),
            if (c?.error != null)
              MaterialBanner(
                content: Text(c!.error!),
                actions: [
                  TextButton(onPressed: c.attach, child: const Text('重試')),
                ],
              ),
            if (c != null && c.exited)
              MaterialBanner(
                content: Text('Shell 已結束（退出碼 ${c.exitCode ?? '—'}）'),
                actions: [
                  TextButton(
                    onPressed: _client.isOnline ? c.restart : null,
                    child: const Text('重新開啟'),
                  ),
                ],
              ),
            if (c?.loading == true) const LinearProgressIndicator(),
            Expanded(
              child: c == null
                  ? _workspaceList()
                  : ColoredBox(
                      color: xterm.TerminalThemes.defaultTheme.background,
                      child: xterm.TerminalView(
                        c.terminal,
                        controller: _selection,
                        focusNode: _focus,
                        autofocus: false,
                        readOnly: !c.canInput,
                        keyboardType: TextInputType.visiblePassword,
                        textStyle: const xterm.TerminalStyle(fontSize: 13),
                        padding: const EdgeInsets.all(8),
                      ),
                    ),
            ),
            if (c != null)
              SafeArea(
                top: false,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 4,
                  ),
                  child: Row(
                    children: [
                      for (final key in [
                        ('Ctrl+C', '\x03'),
                        ('Tab', '\t'),
                        ('Esc', '\x1b'),
                      ])
                        TextButton(
                          onPressed: c.canInput
                              ? () => unawaited(c.write(key.$2))
                              : null,
                          child: Text(key.$1),
                        ),
                      for (final key in [
                        ('↑', xterm.TerminalKey.arrowUp),
                        ('↓', xterm.TerminalKey.arrowDown),
                        ('←', xterm.TerminalKey.arrowLeft),
                        ('→', xterm.TerminalKey.arrowRight),
                      ])
                        TextButton(
                          onPressed: c.canInput
                              ? () {
                                  c.terminal.keyInput(key.$2);
                                }
                              : null,
                          child: Text(key.$1),
                        ),
                      IconButton(
                        tooltip: '貼上',
                        onPressed: c.canInput ? _paste : null,
                        icon: const Icon(Icons.content_paste_rounded),
                      ),
                      IconButton(
                        tooltip: _focus.hasFocus ? '收起鍵盤' : '鍵盤',
                        onPressed: c.canInput
                            ? () => _focus.hasFocus
                                  ? _focus.unfocus()
                                  : _focus.requestFocus()
                            : null,
                        icon: const Icon(Icons.keyboard_outlined),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _workspaceList() {
    if (_loadingRoots) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: TextButton(onPressed: _loadRoots, child: Text('$_error\n點一下重試')),
      );
    }
    if (_roots.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _client.isOnline
                ? '尚無工作目錄，請在 bridge 設定 workspace 或先建立對話'
                : '連上 bridge 後選擇工作目錄',
          ),
        ),
      );
    }
    return ContentScrollFrame(
      builder: (context, padding) => ListView(
        padding: padding,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('在電腦上的資料夾開啟 shell'),
          ),
          for (final root in _roots)
            ListTile(
              leading: const Icon(Icons.terminal_rounded),
              title: Text('${root['name'] ?? folderName('${root['path']}')}'),
              subtitle: Text('${root['path']}'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: _client.isOnline ? () => _open('${root['path']}') : null,
            ),
        ],
      ),
    );
  }
}
