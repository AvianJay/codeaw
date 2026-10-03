/// Presentation facts from ACP's ordinary tool-call representation. Keep this
/// tolerant of older adapters, but never infer delegation from free-form prose.
String? nonEmptyString(Object? value) => value is String && value.trim().isNotEmpty ? value.trim() : null;

Map<dynamic, dynamic> objectMap(Object? value) => value is Map ? value : const {};

String? subagentParentId(Object? metadata) {
  final meta = objectMap(metadata);
  return nonEmptyString(objectMap(meta['claudeCode'])['parentToolUseId']) ?? nonEmptyString(meta['parentToolCallId']);
}

enum SubagentStatus { pending, running, completed, failed, cancelled, disconnected, unknown }

SubagentStatus subagentStatusOf(Object? value) => switch (value) {
  'pending' || 'pendingInit' => SubagentStatus.pending,
  'in_progress' || 'inProgress' || 'running' => SubagentStatus.running,
  'completed' => SubagentStatus.completed,
  'failed' || 'errored' => SubagentStatus.failed,
  'cancelled' || 'canceled' || 'interrupted' || 'shutdown' => SubagentStatus.cancelled,
  'disconnected' || 'notFound' => SubagentStatus.disconnected,
  _ => SubagentStatus.unknown,
};

class SubagentInfo {
  const SubagentInfo({required this.name, this.task, this.role, this.model, this.threadIds = const [], this.launchOnly = false});

  final String name;
  final String? task;
  final String? role;
  final String? model;
  final List<String> threadIds;
  // Codex completing spawnAgent means the spawn succeeded, not that its child finished.
  final bool launchOnly;

  static SubagentInfo? fromTool({String? name, String? title, Object? input, Object? output, Object? metadata}) {
    final raw = objectMap(input);
    final meta = objectMap(metadata);
    final claude = objectMap(meta['claudeCode']);
    final air = objectMap(objectMap(meta['jetbrains'])['air']);
    final toolName = nonEmptyString(claude['toolName']) ?? name ?? title ?? '';
    final normalized = toolName.replaceAll('_', '').toLowerCase();
    final spawn = normalized == 'spawnagent';
    final activity = nonEmptyString(raw['agentThreadId']) != null && nonEmptyString(raw['agentPath']) != null;
    if (!const ['agent', 'task'].contains(normalized) &&
        !spawn &&
        !activity &&
        air['subagent'] != true &&
        claude['subagent'] != true &&
        nonEmptyString(raw['subagent_type']) == null) {
      return null;
    }
    final role = nonEmptyString(raw['subagent_type']) ?? nonEmptyString(raw['agent_type']);
    final path = nonEmptyString(raw['agentPath']);
    final pathName = path?.split('/').where((s) => s.isNotEmpty).lastOrNull;
    final label =
        nonEmptyString(raw['description']) ??
        nonEmptyString(raw['name']) ??
        pathName ??
        (const ['agent', 'task', 'spawnagent'].contains(normalized) ? role : nonEmptyString(title));
    final ids = <String>{
      if (raw['receiverThreadIds'] is List) ...[
        for (final id in raw['receiverThreadIds'])
          if (nonEmptyString(id) != null) id as String,
      ],
      if (nonEmptyString(raw['agentThreadId']) case final String id) id,
      if (nonEmptyString(objectMap(output)['agent_id']) case final String id) id,
    };
    return SubagentInfo(
      name: label ?? '子代理',
      task: nonEmptyString(raw['prompt']) ?? nonEmptyString(raw['message']),
      role: role,
      model: nonEmptyString(raw['model']),
      threadIds: ids.toList(),
      launchOnly: spawn || (activity && raw['activityKind'] == 'started'),
    );
  }
}
