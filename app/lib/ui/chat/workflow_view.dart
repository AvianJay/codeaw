import 'dart:convert';

import 'package:flutter/material.dart';

import '../../data/session_controller.dart';
import '../../data/subagent.dart';
import '../../data/timeline.dart';
import '../../data/workflow.dart';
import '../common/code_view.dart';

/// Planned phases from the script, then any phase only the agents report.
List<({String title, int done, int total})> workflowPhaseProgress(Timeline timeline, ToolItem tool, WorkflowInfo workflow) {
  final counts = <String, ({int done, int total})>{for (final phase in workflow.phases) phase.title: (done: 0, total: 0)};
  for (final child in timeline.childrenOf(tool).whereType<ToolItem>()) {
    final phase = WorkflowAgentInfo.of(child.meta)?.phase;
    if (phase == null) continue;
    final count = counts[phase] ?? (done: 0, total: 0);
    final done = timeline.statusOfSubagent(child) == SubagentStatus.completed;
    counts[phase] = (done: count.done + (done ? 1 : 0), total: count.total + 1);
  }
  return [for (final MapEntry(:key, :value) in counts.entries) (title: key, done: value.done, total: value.total)];
}

class WorkflowPhaseChips extends StatelessWidget {
  const WorkflowPhaseChips({super.key, required this.timeline, required this.tool, required this.workflow});
  final Timeline timeline;
  final ToolItem tool;
  final WorkflowInfo workflow;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final phases = workflowPhaseProgress(timeline, tool, workflow);
    if (phases.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 6,
      runSpacing: 5,
      children: [
        for (final phase in phases)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: phase.total == 0 ? null : scheme.secondaryContainer.withValues(alpha: 0.6),
              border: Border.all(color: scheme.outlineVariant.withValues(alpha: phase.total == 0 ? 0.8 : 0)),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              phase.total == 0 ? phase.title : '${phase.title} ${phase.done}/${phase.total}',
              style: TextStyle(fontSize: 11, color: phase.total == 0 ? scheme.outline : scheme.onSecondaryContainer),
            ),
          ),
      ],
    );
  }
}

/// The launch, result and script of a Workflow, below its agents.
class WorkflowDetails extends StatefulWidget {
  const WorkflowDetails(this.tool, {super.key, required this.controller});
  final ToolItem tool;
  final SessionController controller;

  @override
  State<WorkflowDetails> createState() => _WorkflowDetailsState();
}

class _WorkflowDetailsState extends State<WorkflowDetails> {
  bool _script = false;
  bool _result = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = widget.tool;
    final workflow = t.workflow;
    if (workflow == null) return const SizedBox.shrink();
    final label = TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: scheme.primary);
    final muted = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);
    final output = objectMap(t.rawOutput);
    final logs = [for (final log in output['logs'] as List? ?? const []) if (nonEmptyString(log) case final String s) s];
    final totals = [
      if (output['agentCount'] case final num n) '${n.toInt()} 個 agent',
      if (output['totalToolCalls'] case final num n) '${n.toInt()} 次工具呼叫',
      if (output['totalTokens'] case final num n) '${_thousands(n.toInt())} tokens',
    ];
    final result = output.containsKey('result') ? output['result'] : null;
    final children = <Widget>[
      if (workflow.error case final String error) SelectableText(error, style: TextStyle(fontSize: 13, color: scheme.error)),
      if (workflow.result != null || logs.isNotEmpty || totals.isNotEmpty || result != null) ...[
        Text('結果', style: label),
        if (workflow.result case final String summary) SelectableText(summary, style: const TextStyle(fontSize: 13)),
        if (totals.isNotEmpty) Text(totals.join(' · '), style: muted),
        for (final log in logs) Text('• $log', style: muted),
        if (result != null)
          _Toggle(
            open: _result,
            label: '回傳值',
            onTap: () => setState(() => _result = !_result),
            child: CodeBlock(code: result is String ? result : const JsonEncoder.withIndent('  ').convert(result), language: result is String ? null : 'json', maxHeight: 320),
          ),
      ],
      if (workflow.phases.any((p) => p.detail != null)) ...[
        Text('階段', style: label),
        for (final phase in workflow.phases)
          Text.rich(TextSpan(children: [
            TextSpan(text: phase.title, style: const TextStyle(fontWeight: FontWeight.w600)),
            if (phase.detail case final String detail) TextSpan(text: ' · $detail', style: TextStyle(color: scheme.onSurfaceVariant)),
          ]), style: const TextStyle(fontSize: 12.5)),
      ],
      if (t.detailsDeferred)
        t.loadingDetails
            ? const LinearProgressIndicator()
            : Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => widget.controller.loadToolDetails(t),
                  icon: const Icon(Icons.download_rounded, size: 16),
                  label: Text(t.detailError ?? '讀取腳本與結果'),
                ),
              ),
      if (workflow.script case final String script)
        _Toggle(
          open: _script,
          label: '腳本 · ${'\n'.allMatches(script).length + 1} 行',
          onTap: () => setState(() => _script = !_script),
          child: CodeBlock(code: script, language: 'javascript', maxHeight: 360),
        ),
      if (workflow.args != null) ...[
        Text('參數', style: label),
        CodeBlock(code: const JsonEncoder.withIndent('  ').convert(workflow.args), language: 'json', maxHeight: 200),
      ],
      SelectableText(
        [
          if (workflow.runId case final String id) 'Run $id',
          if (workflow.resumeFromRunId case final String id) '接續 $id',
          if (workflow.taskId case final String id) 'Task $id',
          if (workflow.sessionUrl case final String url) url,
          if (workflow.scriptPath case final String path) path,
        ].join('\n'),
        style: TextStyle(fontSize: 11, color: scheme.outline),
      ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final c in children) Padding(padding: const EdgeInsets.only(top: 6), child: c),
      ]),
    );
  }

  static String _thousands(int n) => n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+$)'), (_) => ',');
}

class _Toggle extends StatelessWidget {
  const _Toggle({required this.open, required this.label, required this.onTap, required this.child});
  final bool open;
  final String label;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 18, color: scheme.primary),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.primary)),
          ]),
        ),
      ),
      if (open) child,
    ]);
  }
}

/// A replayed `<task-notification>`: a status line instead of the raw tags the model read.
class TaskNotificationView extends StatefulWidget {
  const TaskNotificationView(this.notice, {super.key});
  final TaskNotification notice;

  @override
  State<TaskNotificationView> createState() => _TaskNotificationViewState();
}

class _TaskNotificationViewState extends State<TaskNotificationView> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final notice = widget.notice;
    final status = notice.subagentStatus;
    final color = status == SubagentStatus.failed ? scheme.error : scheme.outline;
    final result = notice.result;
    final title = switch (status) {
      SubagentStatus.completed => '背景工作已完成',
      SubagentStatus.failed => '背景工作失敗',
      SubagentStatus.cancelled => '背景工作已停止',
      _ => '背景工作通知',
    };
    final text = notice.summary == null ? title : '$title：${notice.summary}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          onTap: result == null ? null : () => setState(() => _open = !_open),
          borderRadius: BorderRadius.circular(6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(
              switch (status) {
                SubagentStatus.completed => Icons.task_alt_rounded,
                SubagentStatus.failed => Icons.error_outline_rounded,
                SubagentStatus.cancelled => Icons.stop_circle_outlined,
                _ => Icons.notifications_none_rounded,
              },
              size: 16,
              color: color,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: TextStyle(fontSize: 12.5, color: color))),
            if (result != null) Icon(_open ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 18, color: scheme.outline),
          ]),
        ),
        if (_open && result != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 24),
            child: CodeBlock(code: _pretty(result), language: _isJson(result) ? 'json' : null, maxHeight: 320, highlight: _isJson(result)),
          ),
      ]),
    );
  }

  static bool _isJson(String text) => text.startsWith('{') || text.startsWith('[');

  static String _pretty(String text) {
    if (!_isJson(text)) return text;
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(text));
    } on FormatException {
      return text;
    }
  }
}
