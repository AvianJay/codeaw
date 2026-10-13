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
  late final TerminalHub _hub;
  bool _choosingFolder = false;
  ShellController? get _shell => _choosingFolder ? null : _hub.active;
  xterm.Terminal? _lastScreen;
  final _activeTabKey = GlobalKey();
  double? _tabsWidth;
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
    _hub = AppScope.read(context).terminals!;
    _hub.addListener(_onHubChanged);
    _connection = _client.connected.listen((_) {
      if (!_hub.initialized) unawaited(_hub.show(cwd: widget.cwd));
      unawaited(_loadRoots());
    });
    unawaited(_hub.show(cwd: widget.cwd));
    unawaited(_loadRoots());
  }

  void _onHubChanged() {
    if (_lastScreen != _shell?.terminal) {
      _lastScreen = _shell?.terminal;
      _focus.unfocus();
      _selection.clearSelection();
      _revealActiveTab();
    }
  }

  void _revealActiveTab() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _activeTabKey.currentContext;
      if (mounted && context != null) {
        unawaited(Scrollable.ensureVisible(context, alignment: .5));
      }
    });
  }

  void _open(String cwd) {
    _focus.unfocus();
    _selection.clearSelection();
    if (_hub.create(cwd) != null) setState(() => _choosingFolder = false);
  }

  void _select(ShellController c) {
    setState(() => _choosingFolder = false);
    _hub.select(c);
  }

  void _chooseFolder() {
    _hub.hide();
    _focus.unfocus();
    _selection.clearSelection();
    setState(() => _choosingFolder = true);
    unawaited(_loadRoots());
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
    _hub.removeListener(_onHubChanged);
    _hub.hide();
    _connection?.cancel();
    _focus.dispose();
    _selection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_client, _hub, _selection]),
      builder: (context, _) => _buildPage(context),
    );
  }

  Widget _buildPage(BuildContext context) {
    final c = _shell;
    return Scaffold(
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
          IconButton(
            tooltip: '新增終端機',
            icon: const Icon(Icons.add_rounded),
            onPressed: _hub.canCreate
                ? () => c == null ? _chooseFolder() : _open(c.cwd)
                : null,
          ),
          if (c != null) ...[
            IconButton(
              tooltip: '複製選取文字',
              icon: const Icon(Icons.copy_outlined),
              onPressed: _selection.selection == null ? null : _copy,
            ),
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'restart') unawaited(c.restart());
                if (v == 'close') unawaited(_hub.close(c));
                if (v == 'clear') c.terminal.write('\x1b[2J\x1b[H\x1b[3J');
                if (v == 'folder') {
                  _chooseFolder();
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'clear', child: Text('清除畫面')),
                PopupMenuItem(
                  value: 'close',
                  enabled: _client.isOnline && !c.loading,
                  child: const Text('關閉終端機'),
                ),
                PopupMenuItem(
                  value: 'restart',
                  enabled: _client.isOnline && !c.loading,
                  child: const Text('關閉並重開 shell'),
                ),
                PopupMenuItem(
                  value: 'folder',
                  enabled: _hub.canCreate,
                  child: const Text('在其他目錄新增'),
                ),
              ],
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          const ConnectionBanner(),
          if (_hub.controllers.isNotEmpty) _tabs(context),
          if (_hub.error != null)
            MaterialBanner(
              content: Text(_hub.error!),
              actions: [
                TextButton(onPressed: _hub.refresh, child: const Text('重試')),
              ],
            ),
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
          if (_hub.loading || c?.loading == true)
            const LinearProgressIndicator(),
          Expanded(
            child: c == null
                ? _workspaceList()
                : ColoredBox(
                    color: xterm.TerminalThemes.defaultTheme.background,
                    child: xterm.TerminalView(
                      c.terminal,
                      key: ObjectKey(c.terminal),
                      controller: _selection,
                      focusNode: _focus,
                      autofocus: false,
                      readOnly: !c.canInput,
                      keyboardType: TextInputType.visiblePassword,
                      // Bundle the font: browser canvas rendering cannot rely on
                      // the host's CSS monospace family for accurate cell widths.
                      textStyle: const xterm.TerminalStyle(
                        fontSize: 13,
                        fontFamily: 'JetBrainsMono',
                      ),
                      padding: const EdgeInsets.all(8),
                    ),
                  ),
          ),
          if (c != null)
            SafeArea(
              top: false,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
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
    );
  }

  Widget _tabs(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerLow,
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (_tabsWidth != constraints.maxWidth) {
            _tabsWidth = constraints.maxWidth;
            _revealActiveTab();
          }
        return SizedBox(
          width: double.infinity,
          height: 48,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  for (final (index, c) in _hub.controllers.indexed)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 3,
                        vertical: 5,
                      ),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 240),
                        child: InputChip(
                          key: c == _shell ? _activeTabKey : ObjectKey(c),
                          selected: c == _shell,
                          avatar: Icon(
                            c.exited
                                ? Icons.stop_circle_outlined
                                : Icons.terminal_rounded,
                            size: 16,
                          ),
                          label: Text(
                            '${folderName(c.cwd)} · ${index + 1}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          tooltip: c.cwd,
                          onPressed: () => _select(c),
                          onDeleted: _client.isOnline && !c.loading
                              ? () => unawaited(_hub.close(c))
                              : null,
                          deleteButtonTooltipMessage: '關閉終端機 ${index + 1}',
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
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
              onTap: _hub.canCreate ? () => _open('${root['path']}') : null,
            ),
        ],
      ),
    );
  }
}
