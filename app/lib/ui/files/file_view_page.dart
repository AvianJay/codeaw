import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../acp/jsonrpc.dart';
import '../../app_state.dart';
import '../../data/models.dart';
import '../common/code_view.dart';
import '../common/adaptive.dart';
import '../common/markdown.dart';
import '../common/widgets.dart';
import 'file_export.dart';

class FileViewPage extends StatefulWidget {
  const FileViewPage({
    super.key,
    required this.path,
    this.line,
    this.embedded = false,
  });
  final String path;
  final int? line;
  final bool embedded;

  @override
  State<FileViewPage> createState() => _FileViewPageState();
}

class _FileViewPageState extends State<FileViewPage> {
  Map<String, dynamic>? _file;
  String? _error;
  bool _wrap = false;
  bool _rendered = true;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({int? maxBytes}) async {
    final client = AppScope.read(context).client!;
    try {
      final r =
          await client.request('_codeaw/fs/read', {
                'path': widget.path,
                'maxBytes': ?maxBytes,
              })
              as Map<String, dynamic>;
      if (!mounted) return;
      setState(() => _file = r);
      final line = widget.line;
      if (line != null && line > 1) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _scroll.hasClients) {
            _scroll.jumpTo(
              ((line - 1) * 16.9).clamp(0.0, _scroll.position.maxScrollExtent),
            );
          }
        });
      }
    } on RpcError catch (e) {
      if (mounted) setState(() => _error = e.detail);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final f = _file;
    final isMarkdown = widget.path.toLowerCase().endsWith('.md');
    Widget body;
    if (_error != null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, style: TextStyle(color: scheme.error)),
        ),
      );
    } else if (f == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (f['binary'] == true) {
      final mime = f['mimeType'] as String?;
      if (mime != null && mime.startsWith('image/')) {
        final client = AppScope.of(context).client!;
        body = InteractiveViewer(
          maxScale: 8,
          child: Center(
            child: Image.network(
              client.httpUri('/api/fs/raw', {'path': widget.path}).toString(),
              headers: client.authHeaders,
              errorBuilder: (_, _, _) => const Text('無法載入圖片'),
            ),
          ),
        );
      } else {
        body = Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  mime?.startsWith('audio/') == true
                      ? Icons.audio_file_outlined
                      : Icons.insert_drive_file_outlined,
                  size: 56,
                  color: scheme.primary,
                ),
                const SizedBox(height: 16),
                Text(folderName(widget.path), textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text(
                  '${formatBytes(f['size'] as num? ?? 0)} · 無法在 App 預覽',
                  style: TextStyle(color: scheme.outline),
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    FilledButton.icon(
                      onPressed: () =>
                          showFileExport(context, path: widget.path),
                      icon: const Icon(Icons.download_rounded),
                      label: const Text('下載檔案'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => showFileExport(
                        context,
                        path: widget.path,
                        action: FileExportAction.share,
                      ),
                      icon: const Icon(Icons.ios_share_rounded),
                      label: const Text('分享檔案'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      }
    } else {
      final text = f['text'] as String? ?? '';
      body = ContentScrollFrame(
        maxWidth: isMarkdown && _rendered ? 880 : double.infinity,
        padding: const EdgeInsets.all(8),
        builder: (context, padding) => ListView(
          controller: _scroll,
          padding: padding,
          children: [
            if (f['truncated'] == true)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '只顯示前 ${text.length} 個字元',
                        style: TextStyle(color: scheme.outline, fontSize: 12),
                      ),
                    ),
                    TextButton(
                      onPressed: () => _load(maxBytes: 4 * 1024 * 1024),
                      child: const Text('載入更多'),
                    ),
                  ],
                ),
              ),
            if (isMarkdown && _rendered)
              Padding(
                padding: const EdgeInsets.all(8),
                child: SelectionArea(
                  child: Markdown(
                    text,
                    client: AppScope.of(context).client,
                    basePath:
                        (RegExp(r'^[a-zA-Z]:[\\/]|^\\\\').hasMatch(widget.path)
                                ? p.windows
                                : p.posix)
                            .dirname(widget.path),
                  ),
                ),
              )
            else
              CodeBlock(
                code: text,
                language: languageForPath(widget.path),
                lineNumbers: true,
                wrap: _wrap,
              ),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              folderName(widget.path),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              widget.path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: scheme.outline),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '下載檔案',
            icon: const Icon(Icons.download_rounded),
            onPressed: () => showFileExport(context, path: widget.path),
          ),
          IconButton(
            tooltip: '分享檔案',
            icon: const Icon(Icons.ios_share_rounded),
            onPressed: () => showFileExport(
              context,
              path: widget.path,
              action: FileExportAction.share,
            ),
          ),
          if (isMarkdown)
            IconButton(
              tooltip: _rendered ? '顯示原始碼' : '顯示排版',
              icon: Icon(
                _rendered ? Icons.code_rounded : Icons.article_outlined,
              ),
              onPressed: () => setState(() => _rendered = !_rendered),
            ),
          if (f?['binary'] != true)
            IconButton(
              tooltip: _wrap ? '不自動換行' : '自動換行',
              icon: Icon(_wrap ? Icons.wrap_text_rounded : Icons.notes_rounded),
              onPressed: () => setState(() => _wrap = !_wrap),
            ),
        ],
      ),
      body: body,
    );
  }
}
