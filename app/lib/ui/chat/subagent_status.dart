import 'package:flutter/material.dart';

import '../../data/subagent.dart';
import '../../data/timeline.dart';

bool subagentIsActive(SubagentStatus status) => status == SubagentStatus.running || status == SubagentStatus.pending;
bool subagentIsUnfinished(SubagentStatus status) => subagentIsActive(status) || status == SubagentStatus.unknown;

String subagentStatusLabel(Timeline timeline, ToolItem tool) {
  final status = timeline.statusOfSubagent(tool);
  if (subagentIsActive(status) && !timeline.running) return '未回報完成';
  return switch (status) {
    SubagentStatus.pending => '等待中',
    SubagentStatus.running => '執行中',
    SubagentStatus.completed => '已完成',
    SubagentStatus.failed => '失敗',
    SubagentStatus.cancelled => '已停止',
    SubagentStatus.disconnected => '已中斷',
    SubagentStatus.unknown => tool.subagent?.launchOnly == true ? '已啟動' : '狀態未知',
  };
}

class SubagentStatusBadge extends StatelessWidget {
  const SubagentStatusBadge({super.key, required this.timeline, required this.tool});
  final Timeline timeline;
  final ToolItem tool;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = timeline.statusOfSubagent(tool);
    final active = subagentIsActive(status) && timeline.running;
    final color = switch (status) {
      SubagentStatus.failed => scheme.error,
      SubagentStatus.completed => scheme.tertiary,
      _ => active ? scheme.primary : scheme.onSurfaceVariant,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (active)
            SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5, color: color))
          else
            Icon(
              switch (status) {
                SubagentStatus.completed => Icons.check_rounded,
                SubagentStatus.failed => Icons.error_outline_rounded,
                SubagentStatus.cancelled => Icons.stop_rounded,
                _ => Icons.circle_outlined,
              },
              size: 12,
              color: color,
            ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              subagentStatusLabel(timeline, tool),
              style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}
