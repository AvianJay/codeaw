import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/bridge_client.dart';
import 'code_view.dart';
import 'markdown_details.dart';
import 'markdown_image.dart';
import 'markdown_link.dart';

/// Agent markdown. `streaming` keeps unfinished code fences cheap while tokens arrive.
class Markdown extends StatelessWidget {
  const Markdown(
    this.data, {
    super.key,
    this.streaming = false,
    this.style,
    this.client,
    this.basePath,
  });

  final String data;
  final bool streaming;
  final TextStyle? style;
  final BridgeClient? client;

  /// Session cwd, or the directory containing a Markdown file.
  final String? basePath;

  @override
  Widget build(BuildContext context) {
    final sections = splitMarkdownDetails(data);
    // Keep interactive blocks outside GptMarkdown's transient streaming tree.
    // Their line keys remain stable as tokens append to this message.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final section in sections)
          if (section.node case final node?)
            MarkdownDetails(
              key: ValueKey(section.line),
              node: node,
              client: client,
              basePath: basePath,
              streaming: streaming && !node.closed,
              style: style,
            )
          else
            _MarkdownText(
              key: ValueKey(section.line),
              data: section.text!,
              client: client,
              basePath: basePath,
              streaming: streaming,
              style: style,
            ),
      ],
    );
  }
}

class _MarkdownText extends StatelessWidget {
  const _MarkdownText({
    super.key,
    required this.data,
    this.client,
    this.basePath,
    required this.streaming,
    this.style,
  });
  final String data;
  final BridgeClient? client;
  final String? basePath;
  final bool streaming;
  final TextStyle? style;

  Future<void> _openLink(BuildContext context, String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
    } else {
      final file = markdownFileLink(url, basePath: basePath);
      if (file != null && client != null) {
        context.push(
          Uri(
            path: '/file',
            queryParameters: {
              'path': file.path,
              if (file.line != null) 'line': '${file.line}',
            },
          ).toString(),
        );
        return;
      }
    }
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('無法開啟這個連結')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return GptMarkdown(
      data,
      style:
          style ??
          Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.45),
      isStreaming: streaming,
      followLinkColor: true,
      imageBuilder: (context, source, width, height) => MarkdownImage(
        source: source,
        client: client,
        basePath: basePath,
        width: width,
        height: height,
      ),
      // System monospace (like code blocks) instead of the bundled Latin-only font, so CJK in `code` renders.
      inlineCodeStyle: const InlineCodeStyle(
        fontFamily: 'monospace',
        fontFamilyFallback: ['Roboto Mono', 'Noto Sans Mono'],
      ),
      onLinkTap: (url, title) => _openLink(context, url),
      codeBuilder: (context, name, code, closed) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: CodeBlock(
          code: code,
          language: name.isEmpty ? null : name,
          highlight: closed,
        ),
      ),
    );
  }
}
