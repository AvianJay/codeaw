import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/timeline.dart';
import '../common/app_theme.dart';
import 'thought_summary.dart';
import 'turn_summary.dart';

/// A turn's actual activity and elapsed wall time; only this widget ticks.
class WorkingIndicator extends StatefulWidget {
  const WorkingIndicator({super.key, required this.timeline, this.waitingForInput = false, this.showThoughts = false, this.now = DateTime.now});

  final Timeline timeline;
  final bool waitingForInput;
  final bool showThoughts;
  final DateTime Function() now;

  @override
  State<WorkingIndicator> createState() => _WorkingIndicatorState();
}

class _WorkingIndicatorState extends State<WorkingIndicator> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.timeline,
      builder: (context, _) {
        final timeline = widget.timeline;
        if (!timeline.running) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        final waiting = timeline.state == 'requires_action';
        final color = waiting ? scheme.warning : scheme.primary;
        final tool = timeline.activeTool;
        final label = waiting
            ? widget.waitingForInput
                  ? '等待你的回覆…'
                  : '等待批准…'
            : switch (timeline.activity) {
                TurnActivity.thinking => '思考中…',
                TurnActivity.responding => '回覆中…',
                TurnActivity.tool when tool?.mcp != null => '使用 MCP 工具中…',
                TurnActivity.tool => switch (tool?.kind) {
                  'read' => '讀取檔案中…',
                  'edit' => '修改檔案中…',
                  'execute' => '執行指令中…',
                  'search' => '搜尋中…',
                  'fetch' => '取得資料中…',
                  'think' => '思考中…',
                  _ => '使用工具中…',
                },
              };
        final startedAt = timeline.turnStartedAt;
        final now = widget.now();
        final elapsed = formatTurnElapsed(startedAt == null ? Duration.zero : now.difference(startedAt));
        final turn = timeline.currentTurn;
        final detail = !waiting && tool?.title?.trim().isNotEmpty == true ? tool!.displayTitle : null;
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
            decoration: BoxDecoration(
              color: waiting ? color.withValues(alpha: 0.08) : scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(CodeawRadii.md),
              border: Border.all(color: waiting ? color.withValues(alpha: 0.35) : scheme.outlineVariant.withValues(alpha: .7)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: waiting
                      ? Icon(Icons.pause_circle_outline_rounded, size: 18, color: color)
                      : SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: color, strokeCap: StrokeCap.round)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // The status leads; the speed and the timer sit at the far end, or on
                      // the next line when large text leaves no room. Nothing is being
                      // timed while the turn waits for an answer.
                      SizedBox(
                        width: double.infinity,
                        child: Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          spacing: 12,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              label,
                              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: color),
                            ),
                            if (!waiting)
                              Wrap(
                                spacing: 10,
                                runSpacing: 4,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  if (turn?.tokensPerSecondAt(now) != null) TurnSpeed(turn: turn, now: now),
                                  Text(
                                    elapsed,
                                    semanticsLabel: '已處理 $elapsed',
                                    style: TextStyle(fontSize: 12, color: scheme.outline, fontFeatures: const [FontFeature.tabularFigures()]),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ),
                      if (detail != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            detail,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12.5, height: 1.4, color: scheme.onSurface),
                          ),
                        ),
                      if (timeline.currentTurn case final turn? when widget.showThoughts)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: ThoughtSummary(key: ValueKey('thoughts:${turn.key}'), turn: turn, live: true),
                        ),
                      if (timeline.queued > 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text('還有 ${timeline.queued} 則排隊', style: TextStyle(fontSize: 12, color: scheme.outline)),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
