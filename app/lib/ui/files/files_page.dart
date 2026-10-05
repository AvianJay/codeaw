import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../acp/jsonrpc.dart';
import '../../app_state.dart';
import '../../data/models.dart';
import '../common/widgets.dart';
import 'file_view_page.dart';

/// Directory listing on the PC (limited by the bridge to workspaces and session folders).
class FilesPage extends StatefulWidget {
  const FilesPage({super.key, required this.path});
  final String path;

  @override
  State<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends State<FilesPage> {
  late String _path = widget.path;
  String? _parent;
  List<Map<String, dynamic>> _entries = [];
  bool _loading = true;
  bool _showHidden = false;
  String? _error;
  String? _selectedPath;

  @override
  void initState() {
    super.initState();
    _load(_path);
  }

  Future<void> _load(String path) async {
    final client = AppScope.read(context).client!;
    setState(() {
      _loading = true;
      _error = null;
      if (path != _path) _selectedPath = null;
    });
    try {
      final r =
          await client.request('_codeaw/fs/list', {'path': path})
              as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _path = r['path'] as String;
        _parent = r['parent'] as String?;
        _entries = (r['entries'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList();
      });
    } on RpcError catch (e) {
      if (mounted) setState(() => _error = e.detail);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final visible = _entries
        .where((e) => _showHidden || !'${e['name']}'.startsWith('.'))
        .toList();
    return PopScope(
      canPop: _parent == null || _path == widget.path,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _parent != null) _load(_parent!);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(folderName(_path)),
              Text(
                _path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: scheme.outline),
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: '終端機',
              icon: const Icon(Icons.terminal_rounded),
              onPressed: () => context.push(
                '/terminal?cwd=${Uri.encodeQueryComponent(_path)}',
              ),
            ),
            IconButton(
              tooltip: _showHidden ? '隱藏 . 開頭的檔案' : '顯示 . 開頭的檔案',
              icon: Icon(
                _showHidden
                    ? Icons.visibility_rounded
                    : Icons.visibility_off_outlined,
              ),
              onPressed: () => setState(() => _showHidden = !_showHidden),
            ),
            IconButton(
              tooltip: 'Git 變更',
              icon: const Icon(Icons.difference_outlined),
              onPressed: () =>
                  context.push('/git?cwd=${Uri.encodeQueryComponent(_path)}'),
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
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _error!,
                          style: TextStyle(color: scheme.error),
                        ),
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        final split = constraints.maxWidth >= 820;
                        final listing = RefreshIndicator(
                          onRefresh: () => _load(_path),
                          child: ListView(
                            children: [
                              if (_parent != null)
                                ListTile(
                                  leading: const Icon(
                                    Icons.arrow_upward_rounded,
                                  ),
                                  title: const Text('..'),
                                  onTap: () => _load(_parent!),
                                ),
                              for (final e in visible)
                                ListTile(
                                  dense: true,
                                  selected: _selectedPath == e['path'],
                                  selectedTileColor: scheme.primaryContainer
                                      .withValues(alpha: .4),
                                  leading: Icon(
                                    e['type'] == 'dir'
                                        ? Icons.folder_rounded
                                        : fileIcon('${e['name']}'),
                                    color: e['type'] == 'dir'
                                        ? scheme.primary
                                        : scheme.outline,
                                  ),
                                  title: Text(
                                    '${e['name']}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: e['type'] == 'dir'
                                      ? null
                                      : Text(
                                          '${formatBytes(e['size'] as num? ?? 0)} ·${timeAgo(DateTime.tryParse('${e['mtime']}'))}',
                                        ),
                                  onTap: () {
                                    final path = '${e['path']}';
                                    if (e['type'] == 'dir') {
                                      _load(path);
                                    } else if (split) {
                                      setState(() => _selectedPath = path);
                                    } else {
                                      context.push(
                                        '/file?path=${Uri.encodeQueryComponent(path)}',
                                      );
                                    }
                                  },
                                ),
                            ],
                          ),
                        );
                        if (!split) return listing;
                        return Row(
                          children: [
                            SizedBox(width: 280, child: listing),
                            const VerticalDivider(width: 1),
                            Expanded(
                              child: _selectedPath == null
                                  ? Center(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Icons.description_outlined,
                                            size: 44,
                                            color: scheme.outlineVariant,
                                          ),
                                          const SizedBox(height: 12),
                                          Text(
                                            '選擇檔案以預覽',
                                            style: TextStyle(
                                              color: scheme.outline,
                                            ),
                                          ),
                                        ],
                                      ),
                                    )
                                  : FileViewPage(
                                      key: ValueKey(_selectedPath),
                                      path: _selectedPath!,
                                      embedded: true,
                                    ),
                            ),
                          ],
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
