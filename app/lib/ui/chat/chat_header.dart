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
        return Row(
          children: [
            if (!configured || constraints.maxWidth >= 210) ...[
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
            if (configured) ...[
              const SizedBox(width: 8),
              SizedBox(
                key: const ValueKey('chat-usage-bars'),
                width: 84,
                child: Tooltip(
                  message: '${average?.label ?? '目前代理'} 平均剩餘額度，點擊查看帳號詳情',
                  child: InkWell(
                    onTap: onUsageTap,
                    borderRadius: BorderRadius.circular(4),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _HeaderBar(
                          label: '週',
                          average: average?.weekly,
                          total: average?.totalAccounts ?? 0,
                        ),
                        const SizedBox(height: 3),
                        _HeaderBar(
                          label: '5小時',
                          average: average?.fiveHour,
                          total: average?.totalAccounts ?? 0,
                        ),
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
  final CpaUsageAverage? average;
  final int total;
  @override
  Widget build(BuildContext context) {
    final value = average?.remainingPercent;
    final text = value == null ? '—' : '${value.toStringAsFixed(1)}%';
    final color = cpaQuotaColor(context, value);
    return Semantics(
      label: '$label 平均剩餘 $text，有效帳號 ${average?.accountCount ?? 0}/$total',
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
            value: value == null ? 0 : value / 100,
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
