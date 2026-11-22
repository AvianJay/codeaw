import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../data/session_controller.dart';
import '../../data/timeline.dart';

const _desktopAsk = 'codeaw-full-access-on-request';

/// Suggest only a mode advertised by this Codex session, including older bridges.
ConfigValue? codexManualApprovalOption(
  SessionController controller,
  ConfigOption mode,
) {
  if (!(controller.desktopSync ||
          const ['codex', 'codex-acp'].contains(controller.agentId)) ||
      mode.id != 'mode' ||
      mode.currentValue != 'agent-full-access') {
    return null;
  }
  final values = mode.values;
  return values.where((v) => v.value == _desktopAsk).firstOrNull ??
      values.where((v) => v.value == 'workspace-write').firstOrNull;
}

final _bareBlock = RegExp(
  r'^\s*(?:rejected:\s*)?blocked by policy\.?\s*$',
  caseSensitive: false,
);
final _processBlock = RegExp(
  r'\bCreateProcess\b[\s\S]*?\brejected:\s*blocked by policy\b',
  caseSensitive: false,
);
bool reportsPolicyBlock(Object? error, {bool allowBare = true}) =>
    error is String &&
    ((allowBare && _bareBlock.hasMatch(error)) ||
        _processBlock.hasMatch(error));

bool toolReportsPolicyBlock(ToolItem t) {
  // A remote service or an ordinary process can report its own policy errors.
  if (t.status != 'failed' || t.mcp != null) return false;
  bool blocked(Object? error) =>
      reportsPolicyBlock(error, allowBare: t.kind == 'execute');
  final raw = t.rawOutput;
  if (raw is Map) {
    final error = raw['error'];
    if (blocked(error is Map ? error['message'] : error)) return true;
  }
  return blocked(t.terminalOutput) ||
      blocked(raw) ||
      (raw is Map && blocked(raw['formatted_output'])) ||
      (t.content ?? const []).any(
        (c) =>
            c['type'] == 'content' &&
            c['content'] is Map &&
            c['content']['type'] == 'text' &&
            blocked(c['content']['text']),
      );
}

/// The original error stays in the timeline. This changes future settings only.
class CodexPolicyHint extends StatelessWidget {
  const CodexPolicyHint(this.controller, {super.key});
  final SessionController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final mode = controller.configOptions
          .where((o) => o.id == 'mode')
          .firstOrNull;
      final target = mode == null
          ? null
          : codexManualApprovalOption(controller, mode);
      if (target == null || mode == null) return const SizedBox.shrink();
      final scope = target.value == _desktopAsk
          ? '只套用於這個桌面對話。'
          : '也會成為新 Codex 對話的預設。';
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '目前的「${mode.currentLabel}」不會詢問。切換後，下個回合可由你處理核准請求；政策明確禁止的操作仍無法核准。$scope',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            TextButton.icon(
              onPressed: () => controller.setConfig(mode, target.value),
              icon: const Icon(Icons.shield_outlined, size: 16),
              label: Text('切換為「${target.name}」'),
            ),
          ],
        ),
      );
    },
  );
}
