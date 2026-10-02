import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../acp/jsonrpc.dart';
import '../../app_state.dart';
import '../../data/models.dart';
import '../common/widgets.dart';

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
    });
    try {
      final r = await client.request('_codeaw/fs/list', {'path': path}) as Map<String, dynamic>;
      setState(() {
        _path = r['path'] as String;
        _parent = r['parent'] as String?;
        _entries = (r['entries'] as List? ?? const []).whereType<Map<String, dynamic>>().toList();
      });
    } on RpcError catch (e) {
      setState(() => _error = e.detail);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _size(num n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final visible = _entries.where((e) => _showHidden || !'${e['name']}'.startsWith('.')).toList();
    return PopScope(
      canPop: _parent == null || _path == widget.path,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _parent != null) _load(_parent!);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(folderName(_path)),
            Text(_path, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: scheme.outline)),
          ]),
          actions: [
            IconButton(tooltip: '終端機', icon: const Icon(Icons.terminal_rounded), onPressed: () => context.push('/terminal?cwd=${Uri.encodeQueryComponent(_path)}')),
            IconButton(
              tooltip: _showHidden ? '隱藏 . 開頭的檔案' : '顯示 . 開頭的檔案',
              icon: Icon(_showHidden ? Icons.visibility_rounded : Icons.visibility_off_outlined),
              onPressed: () => setState(() => _showHidden = !_showHidden),
            ),
            IconButton(tooltip: 'Git 變更', icon: const Icon(Icons.difference_outlined), onPressed: () => context.push('/git?cwd=${Uri.encodeQueryComponent(_path)}')),
          ],
        ),
        body: Column(children: [
          const ConnectionBanner(),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, style: TextStyle(color: scheme.error))))
                    : RefreshIndicator(
                        onRefresh: () => _load(_path),
                        child: ListView(children: [
                          if (_parent != null)
                            ListTile(leading: const Icon(Icons.arrow_upward_rounded), title: const Text('..'), onTap: () => _load(_parent!)),
                          for (final e in visible)
                            ListTile(
                              dense: true,
                              leading: Icon(e['type'] == 'dir' ? Icons.folder_rounded : _fileIcon('${e['name']}'), color: e['type'] == 'dir' ? scheme.primary : scheme.outline),
                              title: Text('${e['name']}'),
                              subtitle: e['type'] == 'dir' ? null : Text('${_size(e['size'] as num? ?? 0)} · ${timeAgo(DateTime.tryParse('${e['mtime']}'))}'),
                              onTap: () => e['type'] == 'dir' ? _load('${e['path']}') : context.push('/file?path=${Uri.encodeQueryComponent('${e['path']}')}'),
                            ),
                        ]),
                      ),
          ),
        ]),
      ),
    );
  }

  IconData _fileIcon(String name) {
    final n = name.toLowerCase();
    if (RegExp(r'\.(png|jpe?g|gif|webp|bmp|svg|ico)$').hasMatch(n)) return Icons.image_outlined;
    if (RegExp(r'\.(md|txt|rst)$').hasMatch(n)) return Icons.article_outlined;
    if (RegExp(r'\.(json|ya?ml|toml|ini|xml|lock)$').hasMatch(n)) return Icons.data_object_rounded;
    return Icons.insert_drive_file_outlined;
  }
}
