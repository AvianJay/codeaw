import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/timeline.dart';

String formatTurnElapsed(Duration elapsed) {
  final seconds = elapsed.isNegative ? 0 : elapsed.inSeconds;
  if (seconds < 60) return '$seconds 秒';
  if (seconds < 3600) return '${seconds ~/ 60} 分 ${seconds % 60} 秒';
  return '${seconds ~/ 3600} 小時 ${(seconds % 3600) ~/ 60} 分 ${seconds % 60} 秒';
}

class TurnSpeed extends StatelessWidget {
  const TurnSpeed({super.key, required this.turn, required this.now});
  final TurnSummaryItem? turn;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final speed = turn?.tokensPerSecondAt(now);
    return Tooltip(
      message: '估算平均輸出速度：含思考文字，耗時包含工具執行與等待。',
      child: Text(
        speed == null ? '— TPS' : '≈${speed.toStringAsFixed(1)} TPS',
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class TurnSummaryView extends StatelessWidget {
  const TurnSummaryView({super.key, required this.turn, this.onReusePrompt});
  final TurnSummaryItem turn;
  final VoidCallback? onReusePrompt;

  Future<void> _copy(BuildContext context, String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(label), duration: const Duration(seconds: 1)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final response = turn.responseText;
    final now = turn.endedAt ?? turn.startedAt;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Divider(
            height: 12,
            color: scheme.outlineVariant.withValues(alpha: 0.6),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              final metrics = Wrap(
                spacing: 12,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TurnSpeed(turn: turn, now: now),
                  Text(
                    '耗時 ${formatTurnElapsed(turn.elapsedAt(now))}',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              );
              final actions = Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '複製回覆',
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    onPressed: response.isEmpty
                        ? null
                        : () => _copy(context, response, '已複製回覆'),
                  ),
                  IconButton(
                    tooltip: '重新使用提示',
                    icon: const Icon(Icons.refresh_rounded, size: 20),
                    onPressed: onReusePrompt,
                  ),
                  PopupMenuButton<String>(
                    tooltip: '更多回合操作',
                    icon: const Icon(Icons.more_horiz_rounded, size: 20),
                    onSelected: (value) => _copy(
                      context,
                      value == 'thought' ? turn.thoughtText : turn.transcript,
                      value == 'thought' ? '已複製思考內容' : '已複製整個回合',
                    ),
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'turn',
                        enabled: turn.transcript.isNotEmpty,
                        child: const Text('複製整個回合'),
                      ),
                      if (turn.thoughtText.isNotEmpty)
                        const PopupMenuItem(
                          value: 'thought',
                          child: Text('複製思考內容'),
                        ),
                    ],
                  ),
                ],
              );
              if (constraints.maxWidth < 400 ||
                  MediaQuery.textScalerOf(context).scale(12) > 16) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [metrics, actions],
                );
              }
              return Row(
                children: [
                  Expanded(child: metrics),
                  actions,
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
