import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../../data/bridge_client.dart';
import 'markdown.dart';

typedef MarkdownSection = ({int line, String? text, MdCustomBlock? node});

/// Split only standalone details blocks, leaving the surrounding Markdown and
/// code examples intact. Each section is identified by its original start line.
List<MarkdownSection> splitMarkdownDetails(String source) {
  final lines = source.split('\n');
  final sections = <MarkdownSection>[];
  var textStart = 0;
  String? fence;
  for (var i = 0; i < lines.length; i++) {
    final fenceMatch = DetailsSyntax._fence.firstMatch(lines[i]);
    if (fence != null) {
      if (fenceMatch != null &&
          fenceMatch[1]!.startsWith(fence[0]) &&
          fenceMatch[1]!.length >= fence.length &&
          lines[i].substring(fenceMatch.end).trim().isEmpty) {
        fence = null;
      }
      continue;
    }
    if (fenceMatch != null) {
      fence = fenceMatch[1];
      continue;
    }
    // Four-space-indented code is also literal Markdown.
    if (lines[i].startsWith('    ') || lines[i].startsWith('\t')) continue;
    final match = const DetailsSyntax().parse(lines, i);
    if (match == null) continue;
    final text = lines.sublist(textStart, i).join('\n');
    if (text.trim().isNotEmpty) {
      sections.add((line: textStart, text: text, node: null));
    }
    sections.add((line: i, text: null, node: match.node));
    i = match.endLine - 1;
    textStart = match.endLine;
  }
  final text = lines.sublist(textStart).join('\n');
  if (text.trim().isNotEmpty) {
    sections.add((line: textStart, text: text, node: null));
  }
  return sections;
}

/// A Markdown container, so tags in code fences stay literal and unfinished
/// streamed bodies can be rendered without waiting for the closing tag.
class DetailsSyntax extends MarkdownBlockSyntax {
  const DetailsSyntax();

  @override
  String get type => 'details';
  @override
  String get prefix => '<details';

  static final _opening = RegExp(
    r'^\s*<details\b([^>]*)>',
    caseSensitive: false,
  );
  static final _tags = RegExp(r'<(/?)details\b[^>]*>|`+', caseSensitive: false);
  static final _fence = RegExp(r'^\s{0,3}(`{3,}|~{3,})');
  static final _summary = RegExp(
    r'^\s*<summary\b[^>]*>([\s\S]*?)</summary\s*>[ \t]*(?:\n)?',
    caseSensitive: false,
  );
  static final _partialSummary = RegExp(
    r'^\s*<summary\b[^>]*>([\s\S]*)',
    caseSensitive: false,
  );
  static final _openAttribute = RegExp(
    r'''(?:^|\s)open(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s]+))?(?=\s|$)''',
    caseSensitive: false,
  );

  @override
  MarkdownBlockMatch? parse(List<String> lines, int startLine) {
    final opening = _opening.firstMatch(lines[startLine]);
    if (opening == null) return null;
    final body = <String>[];
    var depth = 1;
    String? fence;
    var end = startLine;
    var closed = false;
    for (; end < lines.length; end++) {
      final line = end == startLine
          ? lines[end].substring(opening.end)
          : lines[end];
      final fenceMatch = _fence.firstMatch(line);
      if (fence != null) {
        if (fenceMatch != null &&
            fenceMatch[1]!.startsWith(fence[0]) &&
            fenceMatch[1]!.length >= fence.length &&
            line.substring(fenceMatch.end).trim().isEmpty) {
          fence = null;
        }
        body.add(line);
        continue;
      }
      if (fenceMatch != null) {
        fence = fenceMatch[1];
        body.add(line);
        continue;
      }
      if (line.startsWith('    ') || line.startsWith('\t')) {
        body.add(line);
        continue;
      }
      String? inlineCode;
      for (final tag in _tags.allMatches(line)) {
        final token = tag[0]!;
        if (token.startsWith('`')) {
          if (inlineCode == null) {
            inlineCode = token;
          } else if (token == inlineCode) {
            inlineCode = null;
          }
          continue;
        }
        if (inlineCode != null) continue;
        depth += tag[1] == '/' ? -1 : 1;
        if (depth == 0) {
          // A block closing tag must finish its line; never discard prose.
          if (line.substring(tag.end).trim().isNotEmpty) return null;
          body.add(line.substring(0, tag.start));
          closed = true;
          break;
        }
      }
      if (closed) break;
      body.add(line);
    }
    var content = body.join('\n');
    final summary = _summary.firstMatch(content);
    final partialSummary = summary == null
        ? _partialSummary.firstMatch(content)
        : null;
    final title = summary?[1] ?? partialSummary?[1] ?? '詳細內容';
    content = summary != null
        ? content.substring(summary.end)
        : partialSummary != null
        ? ''
        : content;
    return MarkdownBlockMatch(
      node: MdCustomBlock(
        type: type,
        body: content.replaceAll(RegExp(r'^(?:[ \t]*\n)+|(?:\n[ \t]*)+$'), ''),
        closed: closed,
        data: (
          summary: title.trim(),
          open: _openAttribute.hasMatch(opening[1]!),
        ),
      ),
      endLine: closed ? end + 1 : end,
    );
  }
}

class MarkdownDetails extends StatefulWidget {
  const MarkdownDetails({
    super.key,
    required this.node,
    this.client,
    this.basePath,
    this.streaming = false,
    this.style,
  });
  final MdCustomBlock node;
  final BridgeClient? client;
  final String? basePath;
  final bool streaming;
  final TextStyle? style;

  @override
  State<MarkdownDetails> createState() => _MarkdownDetailsState();
}

class _MarkdownDetailsState extends State<MarkdownDetails> {
  bool? _expanded;

  @override
  Widget build(BuildContext context) {
    final data = widget.node.data as ({String summary, bool open});
    final expanded = _expanded ?? data.open;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: expanded,
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => setState(() => _expanded = !expanded),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 20,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Markdown(
                        data.summary.isEmpty ? '詳細內容' : data.summary,
                        style: widget.style,
                        client: widget.client,
                        basePath: widget.basePath,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (expanded && widget.node.body.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Markdown(
                widget.node.body,
                streaming: widget.streaming,
                style: widget.style,
                client: widget.client,
                basePath: widget.basePath,
              ),
            ),
        ],
      ),
    );
  }
}
