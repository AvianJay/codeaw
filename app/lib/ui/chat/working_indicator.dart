import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/timeline.dart';
import 'turn_summary.dart';

/// A turn's actual activity and elapsed wall time; only this widget ticks.
class WorkingIndicator extends StatefulWidget {
  const WorkingIndicator({super.key, required this.timeline, this.waitingForInput = false, this.now = DateTime.now});

  final Timeline timeline;
  final bool waitingForInput;
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
        final color = waiting ? Colors.orange.shade800 : scheme.primary;
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
        final elapsed = startedAt == null ? Duration.zero : widget.now().difference(startedAt);
        final detail = !waiting && tool?.title?.trim().isNotEmpty == true ? tool!.displayTitle : null;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: waiting ? color.withValues(alpha: 0.08) : scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: waiting ? color.withValues(alpha: 0.25) : scheme.outlineVariant),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: waiting
                      ? Icon(Icons.pause_circle_outline_rounded, size: 18, color: color)
                      : SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: color)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 12,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            label,
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color),
                          ),
                          TurnSpeed(turn: timeline.currentTurn, now: widget.now()),
                          Text(
                            '已處理 ${formatTurnElapsed(elapsed)}',
                            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()]),
                          ),
                        ],
                      ),
                      if (detail != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            detail,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                          ),
                        ),
                      if (timeline.queued > 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text('還有 ${timeline.queued} 則排隊', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
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
