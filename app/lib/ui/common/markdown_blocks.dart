import 'package:gpt_markdown/gpt_markdown.dart';

import 'markdown_details.dart';
import 'markdown_visualization.dart';

typedef MarkdownSection = ({int line, String? text, MdCustomBlock? node});

/// Split standalone interactive blocks while leaving code examples literal.
/// Original line keys keep their state stable as streamed tokens append.
List<MarkdownSection> splitMarkdownBlocks(
  String source, {
  bool streaming = false,
}) {
  final lines = source.split('\n');
  final sections = <MarkdownSection>[];
  var textStart = 0;
  String? fence;
  final fences = RegExp(r'^\s{0,3}(`{3,}|~{3,})');
  for (var i = 0; i < lines.length; i++) {
    final fenceMatch = fences.firstMatch(lines[i]);
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
    if (lines[i].startsWith('    ') || lines[i].startsWith('\t')) continue;
    final match =
        const DetailsSyntax().parse(lines, i) ??
        const VisualizationSyntax().parse(lines, i, streaming: streaming);
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
