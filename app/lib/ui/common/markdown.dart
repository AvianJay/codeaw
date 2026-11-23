import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/bridge_client.dart';
import 'app_theme.dart';
import 'code_view.dart';
import 'link_text.dart';
import 'markdown_blocks.dart';
import 'markdown_details.dart';
import 'markdown_image.dart';
import 'markdown_link.dart';
import 'markdown_visualization.dart';

/// Replaces the system launcher in tests.
@visibleForTesting
Future<bool> Function(Uri uri)? debugLinkLauncher;

/// Schemes handed to the system; anything else must resolve to a bridge file.
const _external = {'http', 'https', 'mailto', 'tel', 'sms'};

/// Opens a link from a message: web and contact links in the system, file
/// links in the bridge file viewer. Says so when it cannot.
Future<void> openLink(
  BuildContext context,
  String url, {
  BridgeClient? client,
  String? basePath,
}) async {
  url = linkTarget(url);
  // A bare host is a web address, as the autolinker already treats it.
  if (RegExp(r'^www\.[^\s/]+\.[^\s/]+', caseSensitive: false).hasMatch(url)) {
    url = 'https://$url';
  }
  final uri = Uri.tryParse(url);
  if (uri != null && _external.contains(uri.scheme.toLowerCase())) {
    try {
      final launch =
          debugLinkLauncher ??
          (Uri uri) => launchUrl(uri, mode: LaunchMode.externalApplication);
      if (await launch(uri)) return;
    } catch (_) {
      // No handler for this scheme on the device.
    }
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
    final sections = splitMarkdownBlocks(data, streaming: streaming);
    // Keep interactive blocks outside GptMarkdown's transient streaming tree.
    // Their line keys remain stable as tokens append to this message.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final section in sections)
          if (section.node case final node?)
            if (node.type == 'visualization')
              MarkdownVisualization(
                key: ValueKey(section.line),
                node: node,
                client: client,
                basePath: basePath,
              )
            else
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

/// Markdown styles sized for chat. The package's defaults are page headlines
/// (up to 32 px, regular weight) and full-contrast table and divider lines.
GptMarkdownThemeData markdownTheme(BuildContext context, TextStyle? base) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  final dark = theme.brightness == Brightness.dark;
  final size = base?.fontSize ?? 14;
  TextStyle heading(double scale, FontWeight weight, [Color? color]) =>
      TextStyle(
        fontSize: size * scale,
        fontWeight: weight,
        height: 1.35,
        letterSpacing: 0,
        color: color ?? scheme.onSurface,
      );
  final line = scheme.outlineVariant.withValues(alpha: dark ? 1 : .9);
  return GptMarkdownTheme.of(context).copyWith(
    h1: heading(1.4, FontWeight.w700),
    h2: heading(1.25, FontWeight.w700),
    h3: heading(1.12, FontWeight.w600),
    h4: heading(1.04, FontWeight.w600),
    h5: heading(1, FontWeight.w600),
    h6: heading(.95, FontWeight.w600, scheme.onSurfaceVariant),
    hrLineThickness: 1,
    hrLineColor: line,
    hrLinePadding: const EdgeInsets.symmetric(vertical: 8),
    autoAddDividerLineAfterH1: false,
    styleSheet: GptMarkdownStyleSheet(
      heading: const HeadingStyle(padding: EdgeInsets.only(top: 6, bottom: 2)),
      list: ListStyle(
        bulletSize: 5,
        bulletColor: scheme.onSurfaceVariant.withValues(alpha: .8),
        markerTextStyle: TextStyle(
          color: scheme.onSurfaceVariant,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      blockQuote: BlockQuoteStyle(
        barWidth: 3,
        barColor: scheme.primary.withValues(alpha: .55),
        barRadius: const Radius.circular(2),
        padding: const EdgeInsetsDirectional.only(start: 12, top: 2, bottom: 2),
        margin: const EdgeInsets.symmetric(vertical: 4),
        textStyle: TextStyle(color: scheme.onSurfaceVariant),
      ),
      table: TableStyle(
        borderColor: line,
        borderRadius: const Radius.circular(CodeawRadii.sm),
        cellPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        headerBackground: scheme.surfaceContainerHigh,
        headerTextStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
      hr: HrStyle(
        color: line,
        thickness: 1,
        padding: const EdgeInsets.symmetric(vertical: 8),
      ),
    ),
  );
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

  @override
  Widget build(BuildContext context) {
    final base =
        style ?? Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.45);
    return GptMarkdownTheme(
      gptThemeData: markdownTheme(context, base),
      child: _markdown(context, base),
    );
  }

  Widget _markdown(BuildContext context, TextStyle? base) {
    return GptMarkdown(
      data,
      style: base,
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
      inlineCodeStyle: InlineCodeStyle(
        fontFamily: 'monospace',
        fontFamilyFallback: const ['Roboto Mono', 'Noto Sans Mono'],
        fontSizeFactor: .9,
        // A soft fill, without the default outline, keeps prose calm.
        backgroundColor: Theme.of(context).colorScheme.onSurface.withValues(
          alpha: Theme.of(context).brightness == Brightness.dark ? .1 : .07,
        ),
        borderColor: Colors.transparent,
        borderWidth: 0,
        borderRadius: const Radius.circular(5),
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
      ),
      onLinkTap: (url, title) =>
          openLink(context, url, client: client, basePath: basePath),
      codeBuilder: (context, name, code, closed) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: CodeBlock(
          code: code,
          language: name.isEmpty ? null : name,
          highlight: closed,
        ),
      ),
    );
  }
}
