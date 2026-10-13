import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:path/path.dart' as p;

import '../../data/bridge_client.dart';
import '../../data/models.dart';
import 'markdown_image.dart';

class VisualizationReference {
  const VisualizationReference({required this.path, this.title});

  final String path;
  final String? title;
}

/// Codex's content reference is an HTML file, not ordinary Markdown.
class VisualizationSyntax extends MarkdownBlockSyntax {
  const VisualizationSyntax();

  @override
  String get type => 'visualization';
  @override
  String get prefix => '\uE200visualize\uE202';

  @override
  MarkdownBlockMatch? parse(
    List<String> lines,
    int startLine, {
    bool streaming = false,
  }) {
    final first = lines[startLine].trimLeft();
    if (!first.startsWith(prefix)) {
      if (streaming &&
          startLine == lines.length - 1 &&
          first.startsWith('\uE200') &&
          prefix.startsWith(first)) {
        return _pending(lines.length);
      }
      return null;
    }
    final payload = <String>[first.substring(prefix.length)];
    var end = startLine;
    for (; ; end++) {
      final closing = payload.last.indexOf('\uE201');
      if (closing >= 0) {
        // Preserve malformed references and any prose after a closing token.
        if (payload.last.substring(closing + 1).trim().isNotEmpty) return null;
        payload[payload.length - 1] = payload.last.substring(0, closing);
        try {
          final data = jsonDecode(payload.join('\n'));
          if (data is! Map<String, dynamic> ||
              data['path'] is! String ||
              (data['path'] as String).trim().isEmpty) {
            return null;
          }
          return MarkdownBlockMatch(
            node: MdCustomBlock(
              type: type,
              body: '',
              closed: true,
              data: VisualizationReference(
                path: data['path'] as String,
                title: data['title'] is String ? data['title'] as String : null,
              ),
            ),
            endLine: end + 1,
          );
        } on FormatException {
          return null;
        }
      }
      if (end + 1 == lines.length) {
        return streaming ? _pending(lines.length) : null;
      }
      payload.add(lines[end + 1]);
    }
  }

  MarkdownBlockMatch _pending(int endLine) => MarkdownBlockMatch(
    node: MdCustomBlock(type: type, body: '', closed: false),
    endLine: endLine,
  );
}

/// JSON paths are literal filesystem paths; do not decode percent signs or
/// treat a filename's hash as a Markdown source-location fragment.
String? visualizationFilePath(String source, {String? basePath}) {
  source = source.trim();
  if (source.isEmpty || source.contains('\u0000')) return null;
  if (RegExp(r'^/[a-zA-Z]:[\\/]').hasMatch(source)) {
    source = source.substring(1);
  }
  final windows = RegExp(r'^[a-zA-Z]:[\\/]|^\\\\');
  if (windows.hasMatch(source)) return p.windows.normalize(source);
  if (source.startsWith('file:')) {
    try {
      return markdownImagePath(source);
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    } on UnsupportedError {
      return null;
    }
  }
  if (source.startsWith('//') ||
      RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:').hasMatch(source)) {
    return null;
  }
  if (p.posix.isAbsolute(source)) return p.posix.normalize(source);
  if (basePath == null || basePath.isEmpty) return null;
  final paths = windows.hasMatch(basePath) ? p.windows : p.posix;
  return paths.normalize(paths.join(basePath, source));
}

/// Other ACP clients do not have Codex's visualization runtime. Keep the
/// generated file accessible through the existing authenticated file viewer.
class MarkdownVisualization extends StatelessWidget {
  const MarkdownVisualization({
    super.key,
    required this.node,
    this.client,
    this.basePath,
  });

  final MdCustomBlock node;
  final BridgeClient? client;
  final String? basePath;

  @override
  Widget build(BuildContext context) {
    final reference = node.data as VisualizationReference?;
    if (!node.closed || reference == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text('正在準備視覺化檔案…'),
      );
    }
    final path = visualizationFilePath(reference.path, basePath: basePath);
    final available = path != null && client != null;
    final title = reference.title?.trim();
    final label = title == null || title.isEmpty
        ? folderName(reference.path)
        : title;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          OutlinedButton.icon(
            onPressed: available
                ? () => context.push(
                    Uri(
                      path: '/file',
                      queryParameters: {'path': path},
                    ).toString(),
                  )
                : null,
            icon: const Icon(Icons.insert_chart_outlined, size: 20),
            label: Text(label),
          ),
          const SizedBox(height: 4),
          Text(
            available ? '查看 HTML 檔案或下載' : '無法開啟視覺化檔案',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
