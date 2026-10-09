import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../acp/jsonrpc.dart';
import '../../app_state.dart';
import '../../data/models.dart';
import '../common/widgets.dart';
import '../common/create_folder.dart';
import 'file_view_page.dart';
import 'file_export.dart';

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
  bool _selecting = false;
  final _selection = <String>{};

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
      if (path != _path) {
        _selectedPath = null;
        _selection.clear();
        _selecting = false;
      }
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
        final paths = _entries.map((entry) => entry['path']).toSet();
        _selection.removeWhere((path) => !paths.contains(path));
        if (!paths.contains(_selectedPath)) _selectedPath = null;
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
      canPop: !_selecting && (_parent == null || _path == widget.path),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selecting) {
          setState(() {
            _selecting = false;
            _selection.clear();
          });
        } else if (!didPop && _parent != null) {
          _load(_parent!);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: _selecting
              ? IconButton(
                  tooltip: '取消選取',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => setState(() {
                    _selecting = false;
                    _selection.clear();
                  }),
                )
              : null,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _selecting ? '已選取 ${_selection.length} 個項目' : folderName(_path),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                _path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: scheme.outline),
              ),
            ],
          ),
          actions: [
            if (_selecting) ...[
              IconButton(
                tooltip: '全選',
                icon: const Icon(Icons.select_all_rounded),
                onPressed: () => setState(() {
                  final paths = visible.map((e) => '${e['path']}').toSet();
                  if (_selection.containsAll(paths)) {
                    _selection.removeAll(paths);
                  } else {
                    _selection.addAll(paths);
                  }
                }),
              ),
            ] else ...[
              IconButton(
                tooltip: '新增資料夾',
                icon: const Icon(Icons.create_new_folder_outlined),
                onPressed: _loading
                    ? null
                    : () async {
                        final path = await showCreateFolder(context, _path);
                        if (path != null && mounted) await _load(path);
                      },
              ),
              IconButton(
                tooltip: '選取檔案',
                icon: const Icon(Icons.checklist_rounded),
                onPressed: _loading
                    ? null
                    : () => setState(() => _selecting = true),
              ),
              PopupMenuButton<String>(
                tooltip: '檔案操作',
                onSelected: (value) async {
                  switch (value) {
                    case 'folder':
                      final path = await showCreateFolder(context, _path);
                      if (path != null && mounted) await _load(path);
                    case 'terminal':
                      if (context.mounted) {
                        context.push(
                          '/terminal?cwd=${Uri.encodeQueryComponent(_path)}',
                        );
                      }
                    case 'hidden':
                      setState(() => _showHidden = !_showHidden);
                    case 'git':
                      if (context.mounted) {
                        context.push(
                          '/git?cwd=${Uri.encodeQueryComponent(_path)}',
                        );
                      }
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'folder',
                    child: ListTile(
                      leading: Icon(Icons.create_new_folder_outlined),
                      title: Text('新增資料夾'),
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'terminal',
                    child: ListTile(
                      leading: Icon(Icons.terminal_rounded),
                      title: Text('終端機'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'hidden',
                    child: ListTile(
                      leading: Icon(
                        _showHidden
                            ? Icons.visibility_rounded
                            : Icons.visibility_off_outlined,
                      ),
                      title: Text(_showHidden ? '隱藏 . 開頭的檔案' : '顯示 . 開頭的檔案'),
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'git',
                    child: ListTile(
                      leading: Icon(Icons.difference_outlined),
                      title: Text('Git 變更'),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
        body: Column(
          children: [
            const ConnectionBanner(),
            if (_selecting)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  alignment: WrapAlignment.center,
                  children: [
                    FilledButton.icon(
                      onPressed:
                          _selection.isEmpty ||
                              !AppScope.of(context).client!.supportsFileArchives
                          ? null
                          : () => showFileExport(
                              context,
                              path: _path,
                              paths: _selection.toList(),
                            ),
                      icon: const Icon(Icons.folder_zip_outlined),
                      label: const Text('打包 ZIP 下載'),
                    ),
                    OutlinedButton.icon(
                      onPressed:
                          _selection.isEmpty ||
                              !AppScope.of(context).client!.supportsFileArchives
                          ? null
                          : () => showFileExport(
                              context,
                              path: _path,
                              paths: _selection.toList(),
                              action: FileExportAction.share,
                            ),
                      icon: const Icon(Icons.ios_share_rounded),
                      label: const Text('打包 ZIP 分享'),
                    ),
                    if (!AppScope.of(context).client!.supportsFileArchives)
                      const Text('請先更新電腦端 bridge 以使用 ZIP'),
                  ],
                ),
              ),
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
                                  selected: _selecting
                                      ? _selection.contains(e['path'])
                                      : _selectedPath == e['path'],
                                  selectedTileColor: scheme.primaryContainer
                                      .withValues(alpha: .4),
                                  leading: _selecting
                                      ? Checkbox(
                                          value: _selection.contains(e['path']),
                                          onChanged: (_) => setState(() {
                                            final path = '${e['path']}';
                                            if (!_selection.remove(path)) {
                                              _selection.add(path);
                                            }
                                          }),
                                        )
                                      : Icon(
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
                                    if (_selecting) {
                                      setState(() {
                                        if (!_selection.remove(path)) {
                                          _selection.add(path);
                                        }
                                      });
                                    } else if (e['type'] == 'dir') {
                                      _load(path);
                                    } else if (split) {
                                      setState(() => _selectedPath = path);
                                    } else {
                                      context.push(
                                        '/file?path=${Uri.encodeQueryComponent(path)}',
                                      );
                                    }
                                  },
                                  onLongPress: () => setState(() {
                                    _selecting = true;
                                    _selection.add('${e['path']}');
                                  }),
                                  trailing: _selecting || e['type'] == 'dir'
                                      ? null
                                      : PopupMenuButton<FileExportAction>(
                                          tooltip: '下載或分享 ${e['name']}',
                                          onSelected: (action) =>
                                              showFileExport(
                                                context,
                                                path: '${e['path']}',
                                                action: action,
                                              ),
                                          itemBuilder: (_) => const [
                                            PopupMenuItem(
                                              value: FileExportAction.save,
                                              child: Text('下載檔案'),
                                            ),
                                            PopupMenuItem(
                                              value: FileExportAction.share,
                                              child: Text('分享檔案'),
                                            ),
                                          ],
                                        ),
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
