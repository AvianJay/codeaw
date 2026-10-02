import 'package:flutter/material.dart';

import '../../util/diff.dart';
import 'code_view.dart';

/// Renders diff lines with +/- coloring and old/new line numbers. Scrolls horizontally.
class DiffView extends StatelessWidget {
  const DiffView({super.key, required this.lines, this.maxHeight});

  final List<DiffLine> lines;
  final double? maxHeight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final base = monoStyle(context, size: 12);
    final addBg = dark ? const Color(0x3326A641) : const Color(0x2226A641);
    final delBg = dark ? const Color(0x33E5534B) : const Color(0x22E5534B);
    if (lines.isEmpty) {
      return Padding(padding: const EdgeInsets.all(8), child: Text('（沒有差異）', style: TextStyle(color: scheme.outline)));
    }
    final rows = <Widget>[];
    for (final l in lines) {
      Color? bg;
      var prefix = ' ';
      var style = base;
      switch (l.kind) {
        case DiffKind.add:
          bg = addBg;
          prefix = '+';
        case DiffKind.remove:
          bg = delBg;
          prefix = '-';
        case DiffKind.hunk:
          style = base.copyWith(color: scheme.primary);
          bg = scheme.primary.withValues(alpha: 0.06);
        case DiffKind.meta:
          style = base.copyWith(color: scheme.outline);
        case DiffKind.context:
          break;
      }
      final numbers = l.kind == DiffKind.hunk || l.kind == DiffKind.meta
          ? '         '
          : '${(l.oldNo?.toString() ?? '').padLeft(4)} ${(l.newNo?.toString() ?? '').padLeft(4)}';
      rows.add(Container(
        color: bg,
        child: Text.rich(
          TextSpan(children: [
            TextSpan(text: '$numbers ', style: base.copyWith(color: scheme.outline)),
            TextSpan(text: l.kind == DiffKind.hunk || l.kind == DiffKind.meta ? l.text : '$prefix${l.text}', style: style),
          ]),
          softWrap: false,
        ),
      ));
    }
    // Rows are at least as wide as the view so the +/- backgrounds span the whole line.
    Widget body = LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: constraints.maxWidth),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: IntrinsicWidth(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows)),
          ),
        ),
      ),
    );
    if (maxHeight != null) {
      body = ConstrainedBox(constraints: BoxConstraints(maxHeight: maxHeight!), child: SingleChildScrollView(child: body));
    }
    return Container(
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(8)),
      clipBehavior: Clip.antiAlias,
      child: body,
    );
  }
}
