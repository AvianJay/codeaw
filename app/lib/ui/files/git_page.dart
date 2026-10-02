import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../acp/jsonrpc.dart';
import '../../app_state.dart';
import '../../data/models.dart';
import '../../util/diff.dart';
import '../common/diff_view.dart';
import '../common/widgets.dart';

/// `git status` of the folder, with the diff of each changed file.
class GitPage extends StatefulWidget {
  const GitPage({super.key, required this.cwd});
  final String cwd;

  @override
  State<GitPage> createState() => _GitPageState();
}

class _GitPageState extends State<GitPage> {
  Map<String, dynamic>? _status;
  String? _error;
  bool _loading = true;
  Map<String, dynamic>? _selectedFile;
  bool _showAll = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final client = AppScope.read(context).client!;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r =
          await client.request('_codeaw/git/status', {'cwd': widget.cwd})
              as Map<String, dynamic>;
      if (!mounted) return;
      setState(() => _status = r);
    } on RpcError catch (e) {
      if (mounted) setState(() => _error = e.detail);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final files = (_status?['files'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final root = _status?['root'] as String?;
    return LayoutBuilder(
      builder: (context, constraints) {
        final split = constraints.maxWidth >= 820;
        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Git 變更'),
                Text(
                  root == null
                      ? folderName(widget.cwd)
                      : '${folderName(root)}${_status?['branch'] != null ? ' · ${_status!['branch']}' : ''}',
                  style: TextStyle(fontSize: 12, color: scheme.outline),
                ),
              ],
            ),
            actions: [
              if (files.isNotEmpty)
                TextButton(
                  onPressed: () {
                    if (split) {
                      setState(() {
                        _selectedFile = null;
                        _showAll = true;
                      });
                    } else {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              DiffPage(cwd: widget.cwd, title: '全部變更'),
                        ),
                      );
                    }
                  },
                  child: const Text('全部 diff'),
                ),
            ],
          ),
          body: Column(
            children: [
              const ConnectionBanner(),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null
                    ? Center(
                        child: Text(
                          _error!,
                          style: TextStyle(color: scheme.error),
                        ),
                      )
                    : root == null
                    ? Center(
                        child: Text(
                          '這個資料夾不是 git repo',
                          style: TextStyle(color: scheme.outline),
                        ),
                      )
                    : _changes(context, files, root, split),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _changes(
    BuildContext context,
    List<Map<String, dynamic>> files,
    String root,
    bool split,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final listing = RefreshIndicator(
      onRefresh: _load,
      child: files.isEmpty
          ? ListView(
              children: [
                const SizedBox(height: 120),
                Center(
                  child: Text(
                    '沒有未提交的變更',
                    style: TextStyle(color: scheme.outline),
                  ),
                ),
              ],
            )
          : ListView(
              children: [
                for (final f in files)
                  _FileTile(
                    f: f,
                    root: root,
                    cwd: widget.cwd,
                    selected:
                        split &&
                        !_showAll &&
                        _selectedFile?['path'] == f['path'],
                    onTap: split
                        ? () => setState(() {
                            _selectedFile = f;
                            _showAll = false;
                          })
                        : null,
                  ),
              ],
            ),
    );
    if (!split || files.isEmpty) return listing;
    final selected = _selectedFile;
    return Row(
      children: [
        SizedBox(width: 300, child: listing),
        const VerticalDivider(width: 1),
        Expanded(
          child: !_showAll && selected == null
              ? Center(
                  child: Text(
                    '選擇檔案以檢視變更',
                    style: TextStyle(color: scheme.outline),
                  ),
                )
              : DiffPage(
                  key: ValueKey(
                    '${selected?['path']}:${selected?['index']}:${selected?['worktree']}:$_showAll',
                  ),
                  cwd: widget.cwd,
                  path: _showAll ? null : '${selected!['path']}',
                  title: _showAll ? '全部變更' : folderName('${selected!['path']}'),
                  staged:
                      !_showAll &&
                      selected!['index'] != ' ' &&
                      selected['index'] != '?' &&
                      selected['worktree'] == ' ',
                  embedded: true,
                ),
        ),
      ],
    );
  }
}

class _FileTile extends StatelessWidget {
  const _FileTile({
    required this.f,
    required this.root,
    required this.cwd,
    this.selected = false,
    this.onTap,
  });
  final Map<String, dynamic> f;
  final String root;
  final String cwd;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final index = '${f['index']}';
    final work = '${f['worktree']}';
    final code = (work != ' ' ? work : index).trim();
    final (String label, Color color) = switch (code) {
      '?' => ('新增', Colors.green.shade600),
      'A' => ('新增', Colors.green.shade600),
      'D' => ('刪除', scheme.error),
      'R' => ('改名', scheme.tertiary),
      _ => ('修改', Colors.orange.shade700),
    };
    final path = '${f['path']}';
    final rel =
        path.length > root.length &&
            path.toLowerCase().startsWith(root.toLowerCase())
        ? path.substring(root.length + 1)
        : path;
    final staged = index != ' ' && index != '?';
    return ListTile(
      selected: selected,
      selectedTileColor: scheme.primaryContainer.withValues(alpha: .4),
      dense: true,
      leading: Container(
        width: 44,
        padding: const EdgeInsets.symmetric(vertical: 3),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      title: Text(folderName(rel)),
      subtitle: Text(
        '$rel${staged ? ' · 已暫存' : ''}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: code == 'D'
          ? null
          : IconButton(
              icon: const Icon(Icons.description_outlined),
              onPressed: () =>
                  context.push('/file?path=${Uri.encodeQueryComponent(path)}'),
            ),
      onTap:
          onTap ??
          () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => DiffPage(
                cwd: cwd,
                path: path,
                title: folderName(rel),
                staged: staged && work == ' ',
              ),
            ),
          ),
    );
  }
}

class DiffPage extends StatefulWidget {
  const DiffPage({
    super.key,
    required this.cwd,
    this.path,
    required this.title,
    this.staged = false,
    this.embedded = false,
  });
  final String cwd;
  final String? path;
  final String title;
  final bool staged;
  final bool embedded;

  @override
  State<DiffPage> createState() => _DiffPageState();
}

class _DiffPageState extends State<DiffPage> {
  List<FileDiff>? _files;
  bool _truncated = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final client = AppScope.read(context).client!;
    try {
      final r =
          await client.request('_codeaw/git/diff', {
                'cwd': widget.cwd,
                'path': ?widget.path,
                'staged': widget.staged,
              })
              as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _files = parseUnifiedDiff(r['diff'] as String? ?? '');
        _truncated = r['truncated'] == true;
      });
    } on RpcError catch (e) {
      if (mounted) setState(() => _error = e.detail);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final files = _files;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        automaticallyImplyLeading: !widget.embedded,
      ),
      body: _error != null
          ? Center(
              child: Text(_error!, style: TextStyle(color: scheme.error)),
            )
          : files == null
          ? const Center(child: CircularProgressIndicator())
          : files.isEmpty
          ? Center(
              child: Text('沒有差異', style: TextStyle(color: scheme.outline)),
            )
          : ListView(
              padding: const EdgeInsets.all(8),
              children: [
                if (_truncated)
                  Text(
                    'diff 太大，只顯示前段',
                    style: TextStyle(color: scheme.outline),
                  ),
                for (final f in files) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            f.path,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        Text(
                          '+${f.added}',
                          style: TextStyle(
                            color: Colors.green.shade600,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '-${f.removed}',
                          style: TextStyle(color: scheme.error, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  DiffView(
                    lines: f.lines
                        .where((l) => l.kind != DiffKind.meta)
                        .toList(),
                  ),
                ],
              ],
            ),
    );
  }
}
