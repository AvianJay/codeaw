import 'package:flutter/material.dart';

import '../../data/cpa_usage.dart';
import '../common/widgets.dart';
import '../usage/quota_color.dart';

String? cpaProviderForAgent(String agentId) => switch (agentId.toLowerCase()) {
  'codex' || 'codex-acp' => 'codex',
  'claude' || 'claude-acp' || 'claude-code' => 'claude',
  'antigravity' || 'antigravity-acp' || 'agy' => 'antigravity',
  'grok' => 'grok',
  _ => null,
};

class ChatHeaderTitle extends StatelessWidget {
  const ChatHeaderTitle({
    super.key,
    required this.title,
    required this.subtitle,
    required this.agentId,
    required this.agentName,
    this.usage,
    this.onUsageTap,
  });
  final String title, subtitle, agentId, agentName;
  final CpaController? usage;
  final VoidCallback? onUsageTap;

  @override
  Widget build(BuildContext context) {
    final controller = usage;
    Widget header() => LayoutBuilder(
      builder: (context, constraints) {
        final configured = controller?.settings != null;
        final provider = cpaProviderForAgent(agentId);
        final average = configured
            ? cpaProviderAverages(
                controller!.accounts,
                controller.quotas,
              ).where((a) => a.provider == provider).firstOrNull
            : null;
        // Windows the provider never reports stay hidden instead of showing —.
        final bars = [
          if (average?.weekly.remainingPercent != null) ('一週', average!.weekly),
          if (average?.fiveHour.remainingPercent != null)
            ('5小時', average!.fiveHour),
        ];
        return Row(
          children: [
            if (bars.isEmpty || constraints.maxWidth >= 210) ...[
              AgentAvatar(agentId: agentId, label: agentName, size: 28),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16),
                  ),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ],
              ),
            ),
            if (bars.isNotEmpty) ...[
              const SizedBox(width: 8),
              SizedBox(
                key: const ValueKey('chat-usage-bars'),
                width: 84,
                child: Tooltip(
                  message:
                      '${average!.label} 平均剩餘額度，點擊查看帳號詳情${average.weekly.staleCount > 0 || average.fiveHour.staleCount > 0 ? '；* 含查詢限流前的上次成功資料' : ''}',
                  child: InkWell(
                    onTap: onUsageTap,
                    borderRadius: BorderRadius.circular(4),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final (i, (label, value)) in bars.indexed) ...[
                          if (i > 0) const SizedBox(height: 3),
                          _HeaderBar(
                            label: label,
                            average: value,
                            total: average.totalAccounts,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
    return controller == null
        ? header()
        : ListenableBuilder(
            listenable: controller,
            builder: (_, _) => header(),
          );
  }
}

class _HeaderBar extends StatelessWidget {
  const _HeaderBar({
    required this.label,
    required this.average,
    required this.total,
  });
  final String label;
  final CpaUsageAverage average;
  final int total;
  @override
  Widget build(BuildContext context) {
    final value = average.remainingPercent!;
    final text =
        '${value.toStringAsFixed(1)}%${average.staleCount > 0 ? '*' : ''}';
    final color = cpaQuotaColor(context, value);
    return Semantics(
      label:
          '$label 平均剩餘 $text，有效帳號 ${average.accountCount}/$total${average.staleCount > 0 ? '，${average.staleCount} 個帳號為限流前的上次成功資料' : ''}',
      excludeSemantics: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 14,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                '$label: $text',
                style: TextStyle(
                  fontSize: 10.5,
                  height: 1,
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          LinearProgressIndicator(
            value: value / 100,
            minHeight: 3,
            color: color,
            backgroundColor: Theme.of(
              context,
            ).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(3),
          ),
        ],
      ),
    );
  }
}
