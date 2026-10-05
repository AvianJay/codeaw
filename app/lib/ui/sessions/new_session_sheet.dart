import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../acp/jsonrpc.dart';
import '../../app_state.dart';
import '../../data/models.dart';
import '../../main.dart';
import '../common/adaptive.dart';
import '../common/widgets.dart';

Future<void> showNewSessionSheet(BuildContext context) {
  return showAdaptiveSheet<void>(
    context: context,
    builder: (_) => const _NewSessionSheet(),
  );
}

class _NewSessionSheet extends StatefulWidget {
  const _NewSessionSheet();

  @override
  State<_NewSessionSheet> createState() => _NewSessionSheetState();
}

class _NewSessionSheetState extends State<_NewSessionSheet> {
  String? _agentId;
  String? _cwd;
  List<({String path, String source})> _roots = [];
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final state = AppScope.read(context);
    final agents = state.client?.agents ?? const [];
    _agentId =
        agents.where((a) => a.status != 'error').firstOrNull?.id ??
        agents.firstOrNull?.id;
    _loadRoots();
  }

  Future<void> _loadRoots() async {
    final state = AppScope.read(context);
    final recent = <String>[];
    for (final s in state.sessions?.sessions ?? const <SessionSummary>[]) {
      if (s.cwd.isNotEmpty && !recent.contains(s.cwd)) recent.add(s.cwd);
      if (recent.length >= 8) break;
    }
    final roots = [for (final r in recent) (path: r, source: 'recent')];
    try {
      final r =
          await state.client!.request('_codeaw/workspaces/list')
              as Map<String, dynamic>;
      for (final w in (r['roots'] as List? ?? const []).whereType<Map>()) {
        if ((w['source'] == 'config' || w['source'] == 'filesystem') && !roots.any((x) => x.path == w['path'])) {
          roots.add((path: '${w['path']}', source: 'workspace'));
        }
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _roots = roots;
      _cwd ??= roots.isEmpty ? null : roots.first.path;
    });
  }

  Future<void> _browse() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final picked = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => FolderPickerPage(start: _cwd)),
    );
    if (mounted && picked != null) setState(() => _cwd = picked);
  }

  Future<void> _manual() async {
    final controller = TextEditingController(text: _cwd);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('資料夾路徑'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: r'D:\proj\myapp'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('確定'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (mounted && v != null && v.isNotEmpty) setState(() => _cwd = v);
  }

  Future<void> _start() async {
    final state = AppScope.read(context);
    final client = state.client!;
    final cwd = _cwd;
    if (_agentId == null || cwd == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final resp =
          await client.request('session/new', {
                'cwd': cwd,
                'mcpServers': const [],
                '_meta': {
                  'codeaw': {'agentId': _agentId},
                },
              })
              as Map<String, dynamic>;
      final id = resp['sessionId'] as String;
      state.hub!.adopt(id, cwd, resp);
      await state.sessions?.refresh();
      if (!mounted) return;
      final router = GoRouter.of(context);
      final wide = MediaQuery.sizeOf(context).width >= tabletBreakpoint;
      Navigator.of(context).pop();
      final route = '${sessionRoute(id)}&cwd=${Uri.encodeQueryComponent(cwd)}';
      if (wide) {
        router.go(route);
      } else {
        router.push(route);
      }
    } on RpcError catch (e) {
      if (mounted) setState(() => _error = e.detail);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final agents = state.client?.agents ?? const <AgentInfo>[];
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('新對話', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            Text('Agent', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final a in agents)
                  ChoiceChip(
                    avatar: AgentAvatar(agentId: a.id, label: a.name, size: 20),
                    showCheckmark: false,
                    label: Text(a.name),
                    selected: _agentId == a.id,
                    onSelected: (_) => setState(() => _agentId = a.id),
                  ),
              ],
            ),
            if (agents
                .where((a) => a.id == _agentId && a.status == 'error')
                .isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '上次啟動失敗：${agents.firstWhere((a) => a.id == _agentId).error ?? ''}',
                  maxLines: 3,
                  style: TextStyle(color: scheme.error, fontSize: 12),
                ),
              ),
            const SizedBox(height: 20),
            Text('資料夾', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: RadioGroup<String>(
                groupValue: _cwd,
                onChanged: (v) => setState(() => _cwd = v),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final r in _roots)
                      RadioListTile<String>(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        value: r.path,
                        title: Text(folderName(r.path)),
                        subtitle: Text(
                          r.path,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11.5),
                        ),
                        secondary: Icon(
                          r.source == 'recent'
                              ? Icons.history_rounded
                              : Icons.folder_special_outlined,
                          size: 20,
                        ),
                      ),
                    if (_cwd != null && !_roots.any((r) => r.path == _cwd))
                      RadioListTile<String>(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        value: _cwd!,
                        title: Text(folderName(_cwd!)),
                        subtitle: Text(
                          _cwd!,
                          style: const TextStyle(fontSize: 11.5),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _browse,
                  icon: const Icon(Icons.folder_open_rounded, size: 18),
                  label: const Text('瀏覽…'),
                ),
                TextButton.icon(
                  onPressed: _manual,
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('輸入路徑'),
                ),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: TextStyle(color: scheme.error)),
              ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy || _agentId == null || _cwd == null
                  ? null
                  : _start,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
              ),
              child: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('開始'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Browse folders on the PC (within the allowed workspaces) and pick one.
class FolderPickerPage extends StatefulWidget {
  const FolderPickerPage({super.key, this.start});
  final String? start;

  @override
  State<FolderPickerPage> createState() => _FolderPickerPageState();
}

class _FolderPickerPageState extends State<FolderPickerPage> {
  String? _path;
  String? _parent;
  List<Map<String, dynamic>> _dirs = [];
  List<Map<String, dynamic>> _roots = [];
  bool _allowAllPaths = false;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _open(widget.start);
  }

  Future<void> _open(String? path) async {
    final client = AppScope.read(context).client!;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (path == null) {
        final r =
            await client.request('_codeaw/workspaces/list')
                as Map<String, dynamic>;
        _roots = (r['roots'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList();
        _allowAllPaths = r['allowAllPaths'] == true;
        _path = null;
        _parent = null;
        _dirs = [];
      } else {
        final r =
            await client.request('_codeaw/fs/list', {'path': path})
                as Map<String, dynamic>;
        _path = r['path'] as String;
        _parent = r['parent'] as String?;
        _dirs = (r['entries'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .where((e) => e['type'] == 'dir')
            .toList();
      }
    } on RpcError catch (e) {
      _error = e.detail;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_path == null ? '選擇資料夾' : folderName(_path!)),
        actions: [
          if (_path != null)
            TextButton(
              onPressed: () => Navigator.pop(context, _path),
              child: const Text('選這裡'),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (_path == null) ...[
                  if (!_allowAllPaths)
                    const Padding(padding: EdgeInsets.all(16), child: Text('要瀏覽其他磁碟，請在電腦 bridge 設定啟用「允許已配對裝置瀏覽所有磁碟與資料夾」。這會讓所有已配對裝置存取此帳號可讀取的檔案；僅在信任配對裝置時啟用。')),
                  if (_roots.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'bridge 設定檔的 workspaces 還沒有任何資料夾。可以在電腦上的 ~/.codeaw/config.yaml 加入，或直接輸入路徑。',
                      ),
                    ),
                  for (final r in _roots)
                    ListTile(
                      leading: const Icon(Icons.folder_special_outlined),
                      title: Text('${r['name']}'),
                      subtitle: Text('${r['path']}'),
                      onTap: () => _open('${r['path']}'),
                    ),
                ] else ...[
                  ListTile(
                    leading: const Icon(Icons.arrow_upward_rounded),
                    title: Text(_parent == null ? '回到工作區清單' : '上一層'),
                    onTap: () => _open(_parent),
                  ),
                  for (final d in _dirs)
                    ListTile(
                      leading: const Icon(Icons.folder_outlined),
                      title: Text('${d['name']}'),
                      onTap: () => _open('${d['path']}'),
                    ),
                ],
              ],
            ),
    );
  }
}
