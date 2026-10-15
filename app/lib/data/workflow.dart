/// Claude Code's Workflow tool. The tool returns once its run is launched in the
/// background; the bridge follows the run (`_meta.codeawWorkflow`) and reports each
/// agent as a child tool call (`_meta.codeawWorkflowAgent`). See docs/protocol.md.
library;

import 'subagent.dart';

class WorkflowPhase {
  const WorkflowPhase(this.title, [this.detail]);
  final String title;
  final String? detail;
}

class WorkflowInfo {
  const WorkflowInfo({
    required this.name,
    this.description,
    this.phases = const [],
    this.script,
    this.scriptPath,
    this.args,
    this.runId,
    this.taskId,
    this.resumeFromRunId,
    this.error,
    this.sessionUrl,
    this.result,
  });

  final String name;
  final String? description;
  final List<WorkflowPhase> phases;
  final String? script;
  final String? scriptPath;
  final Object? args;
  final String? runId;
  final String? taskId;
  final String? resumeFromRunId;

  /// The launch failed its syntax check.
  final String? error;

  /// A `remote: true` run executes in a cloud session.
  final String? sessionUrl;

  /// The task notification's summary of how the run ended.
  final String? result;

  static WorkflowInfo? fromTool({String? name, String? title, Object? input, Object? metadata}) {
    final meta = objectMap(metadata);
    final claude = objectMap(meta['claudeCode']);
    final run = objectMap(meta['codeawWorkflow']);
    final toolName = nonEmptyString(claude['toolName']) ?? (name == 'Workflow' && (title == null || title == name) ? name : null);
    if (toolName != 'Workflow' && run.isEmpty) return null;
    final raw = objectMap(input);
    final response = objectMap(claude['toolResponse']);
    final script = nonEmptyString(raw['script']);
    final scriptMeta = script == null ? const <String, Object?>{} : workflowScriptMeta(script) ?? const <String, Object?>{};
    final scriptPath = nonEmptyString(raw['scriptPath']) ?? nonEmptyString(response['scriptPath']);
    return WorkflowInfo(
      name: nonEmptyString(response['workflowName']) ??
          nonEmptyString(run['name']) ??
          nonEmptyString(scriptMeta['name']) ??
          nonEmptyString(raw['name']) ??
          _scriptName(scriptPath) ??
          'Workflow',
      description: nonEmptyString(response['summary']) ?? nonEmptyString(run['summary']) ?? nonEmptyString(scriptMeta['description']),
      phases: [
        if (scriptMeta['phases'] case final List phases)
          for (final phase in phases)
            if (nonEmptyString(objectMap(phase)['title']) case final String title) WorkflowPhase(title, nonEmptyString(objectMap(phase)['detail'])),
      ],
      script: script,
      scriptPath: scriptPath,
      args: raw['args'],
      runId: nonEmptyString(response['runId']) ?? nonEmptyString(run['runId']),
      taskId: nonEmptyString(response['taskId']) ?? nonEmptyString(run['taskId']),
      resumeFromRunId: nonEmptyString(raw['resumeFromRunId']),
      error: nonEmptyString(response['error']),
      sessionUrl: nonEmptyString(response['sessionUrl']),
      result: nonEmptyString(run['result']),
    );
  }

  /// `…/workflows/scripts/<name>-wf_<id>.js`
  static String? _scriptName(String? path) {
    final file = path?.split(RegExp(r'[\\/]')).last;
    if (file == null) return null;
    return nonEmptyString(file.replaceFirst(RegExp(r'(-wf_[\w-]+)?\.[cm]?js$'), ''));
  }
}

/// The run lifecycle that the bridge reports while it follows the run.
SubagentStatus? workflowRunStatus(Object? metadata) => switch (objectMap(objectMap(metadata)['codeawWorkflow'])['state']) {
  'running' => SubagentStatus.running,
  'completed' => SubagentStatus.completed,
  'failed' => SubagentStatus.failed,
  'stopped' => SubagentStatus.cancelled,
  _ => null,
};

/// One agent of a workflow run, as the bridge reports it.
class WorkflowAgentInfo {
  const WorkflowAgentInfo({required this.agentId, this.label, this.phase, this.model, this.state});
  final String agentId;
  final String? label;
  final String? phase;
  final String? model;
  final String? state;

  static WorkflowAgentInfo? of(Object? metadata) {
    final agent = objectMap(objectMap(metadata)['codeawWorkflowAgent']);
    final id = nonEmptyString(agent['agentId']);
    if (id == null) return null;
    return WorkflowAgentInfo(
      agentId: id,
      label: nonEmptyString(agent['label']),
      phase: nonEmptyString(agent['phase']),
      model: nonEmptyString(agent['model']),
      state: nonEmptyString(agent['state']),
    );
  }
}

/// Claude Code's model-facing report that a background task ended. Replayed
/// histories carry it as a user message.
class TaskNotification {
  const TaskNotification({this.taskId, this.toolUseId, this.status, this.summary, this.result});
  final String? taskId;
  final String? toolUseId;
  final String? status;
  final String? summary;
  final String? result;

  SubagentStatus? get subagentStatus => switch (status) {
    'completed' => SubagentStatus.completed,
    'failed' => SubagentStatus.failed,
    'killed' || 'stopped' || 'cancelled' => SubagentStatus.cancelled,
    _ => null,
  };

  static final _body = RegExp(r'^\s*<task-notification>([\s\S]*?)(?:</task-notification>\s*$|$)');

  static TaskNotification? parse(String text) {
    final body = _body.firstMatch(text)?.group(1);
    if (body == null) return null;
    final split = body.indexOf('<result>');
    final head = split < 0 ? body : body.substring(0, split);
    String? tag(String source, String name) {
      final match = RegExp('<$name>([\\s\\S]*?)</$name>').firstMatch(source);
      return match == null ? null : nonEmptyString(_unescape(match.group(1)!));
    }
    final result = split < 0 ? null : body.substring(split + 8);
    final end = result?.lastIndexOf('</result>') ?? -1;
    return TaskNotification(
      taskId: tag(head, 'task-id'),
      toolUseId: tag(head, 'tool-use-id'),
      status: tag(head, 'status'),
      summary: tag(head, 'summary'),
      result: result == null ? null : nonEmptyString(end < 0 ? result : result.substring(0, end)),
    );
  }

  static String _unescape(String text) => text.replaceAllMapped(
    RegExp('&(amp|lt|gt|quot|apos);'),
    (m) => const {'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'"}[m.group(1)]!,
  );
}

/// `export const meta = { name, description, phases }` is a pure literal by
/// contract, so it can be read without evaluating the script.
Map<String, Object?>? workflowScriptMeta(String script) {
  final start = RegExp(r'(?:^|\n)\s*(?:export\s+)?const\s+meta\s*=\s*').firstMatch(script);
  if (start == null) return null;
  final value = _JsLiteral(script, start.end).value();
  return value is Map<String, Object?> ? value : null;
}

/// Reads the JavaScript literal subset that workflow metadata uses.
class _JsLiteral {
  _JsLiteral(this.source, this.i);
  final String source;
  int i;

  Object? value() {
    try {
      return _value();
    } on FormatException {
      return null;
    }
  }

  Never _fail() => throw const FormatException('not a literal');

  void _skip() {
    while (i < source.length) {
      final c = source[i];
      if (c == ' ' || c == '\n' || c == '\r' || c == '\t') {
        i++;
      } else if (source.startsWith('//', i)) {
        final end = source.indexOf('\n', i);
        i = end < 0 ? source.length : end + 1;
      } else if (source.startsWith('/*', i)) {
        final end = source.indexOf('*/', i + 2);
        if (end < 0) _fail();
        i = end + 2;
      } else {
        return;
      }
    }
  }

  Object? _value() {
    _skip();
    if (i >= source.length) _fail();
    final c = source[i];
    if (c == '{') return _object();
    if (c == '[') return _array();
    if (c == "'" || c == '"' || c == '`') return _string();
    final word = RegExp(r'-?(?:\d+\.?\d*(?:e[+-]?\d+)?|\.\d+)|true\b|false\b|null\b|undefined\b').matchAsPrefix(source, i);
    if (word == null) _fail();
    i = word.end;
    return switch (word.group(0)) {
      'true' => true,
      'false' => false,
      'null' || 'undefined' => null,
      final number => num.parse(number!),
    };
  }

  Map<String, Object?> _object() {
    i++;
    final out = <String, Object?>{};
    while (true) {
      _skip();
      if (i >= source.length) _fail();
      if (source[i] == '}') {
        i++;
        return out;
      }
      final String key;
      if (source[i] == "'" || source[i] == '"') {
        key = _string();
      } else {
        final name = RegExp(r'[A-Za-z_$][\w$]*|\d+').matchAsPrefix(source, i);
        if (name == null) _fail();
        key = name.group(0)!;
        i = name.end;
      }
      _skip();
      if (i >= source.length || source[i] != ':') _fail();
      i++;
      out[key] = _value();
      _skip();
      if (i < source.length && source[i] == ',') {
        i++;
      } else if (i >= source.length || source[i] != '}') {
        _fail();
      }
    }
  }

  List<Object?> _array() {
    i++;
    final out = <Object?>[];
    while (true) {
      _skip();
      if (i >= source.length) _fail();
      if (source[i] == ']') {
        i++;
        return out;
      }
      out.add(_value());
      _skip();
      if (i < source.length && source[i] == ',') {
        i++;
      } else if (i >= source.length || source[i] != ']') {
        _fail();
      }
    }
  }

  String _string() {
    final quote = source[i++];
    final out = StringBuffer();
    while (i < source.length) {
      final c = source[i++];
      if (c == quote) return out.toString();
      if (quote == '`' && c == r'$' && i < source.length && source[i] == '{') _fail();
      if (c != r'\') {
        out.write(c);
        continue;
      }
      if (i >= source.length) _fail();
      final e = source[i++];
      switch (e) {
        case 'n':
          out.write('\n');
        case 't':
          out.write('\t');
        case 'r':
          out.write('\r');
        case 'u':
          final braced = i < source.length && source[i] == '{';
          final end = braced ? source.indexOf('}', i) : i + 4;
          if (end < 0 || end > source.length) _fail();
          final code = int.tryParse(source.substring(braced ? i + 1 : i, end), radix: 16);
          if (code == null) _fail();
          out.writeCharCode(code);
          i = braced ? end + 1 : end;
        case '\n':
          break;
        default:
          out.write(e);
      }
    }
    _fail();
  }
}
