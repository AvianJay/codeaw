import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

import 'code_view.dart';

/// Agent markdown. `streaming` keeps unfinished code fences cheap while tokens arrive.
class Markdown extends StatelessWidget {
  const Markdown(this.data, {super.key, this.streaming = false, this.style});

  final String data;
  final bool streaming;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return GptMarkdown(
      data,
      style: style ?? Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.45),
      isStreaming: streaming,
      followLinkColor: true,
      // System monospace (like code blocks) instead of the bundled Latin-only font, so CJK in `code` renders.
      inlineCodeStyle: const InlineCodeStyle(fontFamily: 'monospace', fontFamilyFallback: ['Roboto Mono', 'Noto Sans Mono']),
      onLinkTap: (url, title) {
        final uri = Uri.tryParse(url);
        if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
          launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      },
      codeBuilder: (context, name, code, closed) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: CodeBlock(code: code, language: name.isEmpty ? null : name, highlight: closed),
      ),
    );
  }
}
