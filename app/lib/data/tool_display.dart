/// Readable labels for tool calls whose adapters only report a machine name.
library;

import 'subagent.dart';

// Claude Code, Kimi and DeepSeek Harness: `mcp__<server>__<tool>`; codex-acp: `mcp.<server>.<tool>`.
final _doubleUnderscore = RegExp(r'^mcp__(.+?)__(.+)$');
final _dotted = RegExp(r'^mcp\.([^.\s]+)\.(\S+)$');

/// A call to a tool provided by an MCP server.
class McpToolRef {
  const McpToolRef({required this.server, required this.tool, this.arguments = const {}});

  /// The server id as the agent reports it.
  final String server;
  final String tool;
  final Map<dynamic, dynamic> arguments;

  /// Claude Code names plugin servers `plugin_<plugin>_<server>` and claude.ai
  /// connectors `claude_ai_<Name>`; the prefixes add nothing on a phone.
  String get serverLabel {
    if (server.startsWith('claude_ai_') && server.length > 10) return server.substring(10).replaceAll('_', ' ');
    if (server.startsWith('plugin_') && server.length > 7) {
      final rest = server.substring(7);
      final half = (rest.length - 1) ~/ 2;
      // `plugin_context7_context7`: the plugin and its server share a name.
      if (rest.length.isOdd && rest[half] == '_' && rest.substring(0, half) == rest.substring(half + 1)) {
        return rest.substring(0, half);
      }
      return rest;
    }
    return server;
  }

  String get label => '$serverLabel · $tool';
}

McpToolRef? mcpToolOf({String? title, String? name, Object? rawInput, Object? metadata}) {
  final input = objectMap(rawInput);
  final candidates = [nonEmptyString(objectMap(objectMap(metadata)['claudeCode'])['toolName']), nonEmptyString(name), nonEmptyString(title)];
  for (final candidate in candidates) {
    if (candidate == null) continue;
    final match = _doubleUnderscore.firstMatch(candidate) ?? _dotted.firstMatch(candidate);
    if (match == null) continue;
    final server = match.group(1)!;
    final tool = match.group(2)!;
    // codex-acp wraps the arguments: `{server, tool, arguments}`.
    final wrapped = input['server'] == server && input['tool'] == tool;
    return McpToolRef(server: server, tool: tool, arguments: wrapped ? objectMap(input['arguments']) : input);
  }
  return null;
}

final _shellWrapper = RegExp(
  r'''^\s*(?:"([^"]+)"|'([^']+)'|(\S+))(?:\s+-(?!c\b|lc\b|Command\b)[A-Za-z]+(?:\s+(?:Bypass|RemoteSigned|Unrestricted|Hidden))?)*\s+(?:-Command|-c|-lc|/c)\s+([\s\S]+)$''',
  caseSensitive: false,
);
const _shells = {'pwsh', 'powershell', 'bash', 'sh', 'zsh', 'cmd'};

/// The command an agent ran, without the shell it was handed to.
///
/// Codex reports `"C:\\…\\pwsh.exe" -Command '<what it ran>'`; the launcher
/// path fills the whole line and says nothing. Anything else is returned as is.
String shellCommand(String command) {
  final match = _shellWrapper.firstMatch(command);
  if (match == null) return command;
  final shell = match.group(1) ?? match.group(2) ?? match.group(3)!;
  var name = shell.split(RegExp(r'[\\/]')).last.toLowerCase();
  if (name.endsWith('.exe')) name = name.substring(0, name.length - 4);
  if (!_shells.contains(name)) return command;
  var inner = match.group(4)!.trim();
  if (inner.length >= 2) {
    final quote = inner[0];
    final body = inner.substring(1, inner.length - 1);
    if (quote == "'" && inner.endsWith("'") && !body.replaceAll("''", '').contains("'")) {
      inner = body.replaceAll("''", "'");
    } else if (quote == '"' && inner.endsWith('"') && !body.replaceAll(r'\"', '').contains('"')) {
      inner = body.replaceAll(r'\"', '"');
    }
  }
  // The same escaping that doubled the launcher's backslashes doubled these.
  if (shell.contains(r'\\')) inner = inner.replaceAll(r'\\', r'\');
  return inner.isEmpty ? command : inner;
}

/// One line of tool title for lists, banners and progress text.
String toolTitle({String? title, String? name, Object? rawInput, Object? metadata}) {
  final mcp = mcpToolOf(title: title, name: name, rawInput: rawInput, metadata: metadata);
  final shown = nonEmptyString(title);
  return argumentTitle(mcp?.arguments ?? objectMap(rawInput)) ?? mcp?.label ?? (shown == null ? null : shellCommand(shown)) ?? nonEmptyString(name) ?? '工具';
}

/// What a shell command is for, when the agent said so alongside it (Claude Code's `description`).
String? commandPurpose(Map<dynamic, dynamic> arguments) =>
    arguments['command'] == null ? null : nonEmptyString(arguments['description'])?.replaceAll(RegExp(r'\s+'), ' ');

/// Some tools include a readable title in the call's JSON arguments.
String? argumentTitle(Map<dynamic, dynamic> arguments) => nonEmptyString(arguments['title'])?.replaceAll(RegExp(r'\s+'), ' ');

/// `key: value` pairs of scalar arguments, for calls whose title does not describe them.
String? argumentSummary(Map<dynamic, dynamic> arguments) {
  final parts = <String>[];
  for (final MapEntry(:key, :value) in arguments.entries) {
    final text = switch (value) {
      String s => nonEmptyString(s)?.replaceAll(RegExp(r'\s+'), ' '),
      num() || bool() => '$value',
      List l when l.isNotEmpty => '[${l.length} 項]',
      Map m when m.isNotEmpty => '{…}',
      _ => null,
    };
    if (text == null) continue;
    parts.add('$key: ${text.length > 120 ? '${text.substring(0, 120)}…' : text}');
    if (parts.length == 6) break;
  }
  return parts.isEmpty ? null : parts.join(' · ');
}
