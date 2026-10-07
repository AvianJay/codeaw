import 'package:flutter/material.dart';

import '../../data/timeline.dart';
import '../common/markdown.dart';

/// One turn's thought summaries, kept compact while Codex streams new sections.
class ThoughtSummary extends StatefulWidget {
  const ThoughtSummary({super.key, required this.turn, this.live = false});

  final TurnSummaryItem turn;
  final bool live;

  @override
  State<ThoughtSummary> createState() => _ThoughtSummaryState();
}

class _ThoughtSummaryState extends State<ThoughtSummary> {
  bool _open = false;

  @override
  void didUpdateWidget(ThoughtSummary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.turn.key != widget.turn.key) _open = false;
  }

  @override
  Widget build(BuildContext context) {
    final thoughts = widget.turn.messages
        .where((m) => m.role == MessageRole.thought)
        .toList();
    // Thought chunks notify their message rather than the whole timeline.
    return ListenableBuilder(
      listenable: Listenable.merge([widget.turn, ...thoughts]),
      builder: (context, _) {
        final texts = thoughts
            .map((m) => m.text.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        if (texts.isEmpty) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        final label = widget.live && !_open
            ? widget.turn.latestThoughtSummary ?? '思考摘要'
            : '思考摘要';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              button: true,
              expanded: _open,
              child: InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () => setState(() => _open = !_open),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      if (!widget.live) ...[
                        Icon(
                          Icons.psychology_alt_outlined,
                          size: 16,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                      ],
                      Expanded(
                        child: Text(
                          label,
                          maxLines: widget.live ? 2 : 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: scheme.onSurfaceVariant,
                            height: 1.35,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Icon(
                        _open
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        size: 18,
                        color: scheme.outline,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (_open)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 4),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 320),
                  child: SingleChildScrollView(
                    child: SelectionArea(
                      child: Markdown(
                        texts.join('\n\n'),
                        style: TextStyle(
                          fontSize: 12.5,
                          color: scheme.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
