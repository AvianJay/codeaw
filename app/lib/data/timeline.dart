import 'package:flutter/foundation.dart';

import 'subagent.dart';
import 'tool_display.dart';

/// Base of everything shown in a session's conversation. Items are mutable and notify
/// their own listeners, so a streaming chunk only rebuilds the bubble it belongs to.
abstract class TimelineItem extends ChangeNotifier {
  TimelineItem(this.key);
  final String key;
  String? parentToolCallId;
  int activityRevision = 0;
  bool _dirty = false;

  void markDirty() => _dirty = true;

  /// Notifies listeners if something changed since the last flush.
  void flush() {
    if (_dirty) {
      _dirty = false;
      notifyListeners();
    }
  }
}

enum MessageRole { user, agent, thought }

enum TurnActivity { thinking, responding, tool }

class MessageItem extends TimelineItem {
  MessageItem(super.key, this.role, this.mid);
  final MessageRole role;
  final String mid;
  final parts = <Map<String, dynamic>>[];
  String? promptId;
  bool queued = false;
  bool steered = false;
  String? receipt;
  bool optimistic = false;
  bool removed = false;

  bool get canRemovePending => role == MessageRole.user && promptId != null &&
      !removed && !steered && receipt != 'read' && dequeued != 'started' &&
      (queued || optimistic || ['sending', 'unknown', 'received', 'failed'].contains(receipt));

  /// `started` / `cancelled` once a queued prompt left the queue.
  String? dequeued;

  String get text => parts.where((p) => p['type'] == 'text').map((p) => p['text'] as String? ?? '').join();

  /// A prompt's text with its file mentions written back as `@name`, for copying and reuse.
  String get promptText => parts
      .map((p) => switch (p['type']) {
            'text' => p['text'] as String? ?? '',
            'resource_link' => '@${p['name'] ?? p['uri'] ?? ''}',
            _ => '',
          })
      .join();

  /// `@name` → link target for each file mention in a prompt.
  Map<String, String> get mentions => {
        for (final p in parts)
          if (p['type'] == 'resource_link' && p['name'] is String && p['uri'] is String) p['name'] as String: p['uri'] as String,
      };
}

/// Folded state of one tool call. Merge rules mirror bridge/src/session/toolcall.ts.
class ToolItem extends TimelineItem {
  ToolItem(super.key, this.toolCallId);
  final String toolCallId;
  String? title;
  String? kind;
  String? status;
  String? name;
  List<Map<String, dynamic>>? content;
  List<Map<String, dynamic>>? locations;
  Object? rawInput;
  Object? rawOutput;
  String terminalOutput = '';
  String? terminalId;
  final meta = <String, dynamic>{};
  int statusRevision = 0;
  int lifecycleRevision = 0;
  int? deferredSeq;
  int hydratedThroughSeq = 0;
  bool deferredDiff = false;
  int? deferredExitCode;
  bool loadingDetails = false;
  String? detailError;

  bool get detailsDeferred => deferredSeq != null;


  SubagentInfo? get subagent => SubagentInfo.fromTool(name: name, title: title, input: rawInput, output: rawOutput, metadata: meta);
  McpToolRef? get mcp => mcpToolOf(title: title, name: name, rawInput: rawInput, metadata: meta);
  String get displayTitle => toolTitle(title: title, name: name, rawInput: rawInput, metadata: meta);

  /// The adapter could only name the tool, so its arguments describe the call.
  bool get bareTitle => mcp != null || (name != null && (title == null || title == name));

  void merge(Map<String, dynamic> u) {
    for (final key in const ['title', 'kind', 'status', 'name', 'rawInput', 'rawOutput']) {
      final v = u[key];
      if (v == null) continue;
      switch (key) {
        case 'title':
          title = '$v';
        case 'kind':
          kind = '$v';
        case 'status':
          status = '$v';
        case 'name':
          name = '$v';
        case 'rawInput':
          rawInput = v;
        case 'rawOutput':
          rawOutput = v;
      }
    }
    final c = u['content'];
    if (c is List) {
      final incoming = c.whereType<Map<String, dynamic>>().toList();
      final oldDiffs = (content ?? const []).where((x) => x['type'] == 'diff').toList();
      final hasDiff = incoming.any((x) => x['type'] == 'diff');
      content = !hasDiff && oldDiffs.isNotEmpty ? [...oldDiffs, ...incoming] : incoming;
    }
    final l = u['locations'];
    if (l is List) locations = l.whereType<Map<String, dynamic>>().toList();
    final m = u['_meta'];
    final deferred = m is Map ? ((m['codeaw'] as Map?)?['deferredTool']) : null;
    if (deferred is Map) {
      deferredSeq = (deferred['seq'] as num?)?.toInt();
      deferredDiff = deferred['hasDiff'] == true;
      deferredExitCode = (deferred['exitCode'] as num?)?.toInt();
      content = null;
      rawOutput = null;
      terminalOutput = '';
    }
    parentToolCallId = subagentParentId(m) ?? parentToolCallId;
    if (m is Map) {
      m.forEach((key, value) {
        if (key == 'terminal_output' || key == 'terminal_output_delta') {
          if (value is Map && value['data'] is String) terminalOutput += value['data'] as String;
          if (value is Map && value['terminal_id'] != null) terminalId = '${value['terminal_id']}';
        } else if (key == 'terminal_info') {
          meta['terminal_info'] = value;
          if (value is Map && value['terminal_id'] != null) terminalId = '${value['terminal_id']}';
        } else if (key == 'claudeCode' && value is Map) {
          meta['claudeCode'] = {...?(meta['claudeCode'] as Map?), ...value};
        } else if (key != 'codeaw') {
          meta[key as String] = value;
        }
      });
    }
    markDirty();
  }

  /// Exit code from `terminal_exit` or rawOutput, when known.
  int? get exitCode {
    final exit = meta['terminal_exit'];
    if (exit is Map && exit['exit_code'] is num) return (exit['exit_code'] as num).toInt();
    final raw = rawOutput;
    if (raw is Map && raw['exit_code'] is num) return (raw['exit_code'] as num).toInt();
    return deferredExitCode;
  }

  bool get hasTerminal => terminalOutput.isNotEmpty || (content ?? const []).any((c) => c['type'] == 'terminal');
}

class PermissionItem extends TimelineItem {
  PermissionItem(super.key, this.requestId);
  final String requestId;
  Map<String, dynamic>? toolCall;
  List<Map<String, dynamic>> options = const [];
  Map<String, dynamic>? outcome;
  String? optionName;
  String? by;
  bool get resolved => outcome != null;
  String get title => (toolCall?['title'] as String?) ?? '工具';
  String get displayTitle => toolTitle(title: toolCall?['title'] as String?, name: toolCall?['name'] as String?, rawInput: toolCall?['rawInput'], metadata: toolCall?['_meta']);
}

class ElicitationItem extends TimelineItem {
  ElicitationItem(super.key, this.requestId);
  final String requestId;
  Map<String, dynamic>? request;
  String? action;
  String? by;
  bool get resolved => action != null;
}

class NoticeItem extends TimelineItem {
  NoticeItem(super.key, this.severity, this.title, this.description);
  final String severity;
  final String title;
  final String? description;
}

class ErrorItem extends TimelineItem {
  ErrorItem(super.key, this.message);
  final String message;
}

class StopItem extends TimelineItem {
  StopItem(super.key, this.stopReason);
  final String stopReason;
}

/// One turn's output and wall time, retained after completion and during replay.
class TurnSummaryItem extends TimelineItem {
  TurnSummaryItem(super.key, {required this.startedAt, this.prompt});

  final DateTime startedAt;
  final MessageItem? prompt;
  DateTime? endedAt;
  final messages = <MessageItem>[];
  final steeredPrompts = <MessageItem>[];
  int _narrowCharacters = 0;
  int _wideCharacters = 0;

  String get responseText => messages.where((m) => m.role == MessageRole.agent).map((m) => m.text).where((s) => s.isNotEmpty).join('\n\n');
  String get thoughtText => messages.where((m) => m.role == MessageRole.thought).map((m) => m.text).where((s) => s.isNotEmpty).join('\n\n');
  /// Latest Codex summary heading, without Markdown markers, for compact views.
  String? get latestThoughtSummary {
    for (final message in messages.reversed) {
      if (message.role != MessageRole.thought) continue;
      final text = message.text.trim();
      if (text.isEmpty) continue;
      final heading = RegExp(r'(?:^|\n)\s*\*\*([^\n]+)').allMatches(text).lastOrNull?.group(1);
      final latest = (heading ?? text.split(RegExp(r'\n\s*\n')).last).trim().replaceAll('**', '').replaceAll(RegExp(r'\s+'), ' ');
      if (latest.isNotEmpty) return latest;
    }
    return null;
  }
  String get transcript => [
        if (prompt != null && prompt!.promptText.isNotEmpty) '你：\n${prompt!.promptText}',
        for (final p in steeredPrompts) if (p.promptText.isNotEmpty) '你（插入回合）：\n${p.promptText}',
        if (responseText.isNotEmpty) 'Agent：\n$responseText',
      ].join('\n\n');

  // A deliberately approximate count: CJK/full-width characters count as one,
  // other characters as one quarter. Chunk boundaries do not affect the count.
  int get estimatedTokens => _wideCharacters + (_narrowCharacters / 4).ceil();

  void recordText(String text) {
    for (final rune in text.runes) {
      if ((rune >= 0x2e80 && rune <= 0xa4cf) ||
          (rune >= 0xac00 && rune <= 0xd7af) ||
          (rune >= 0xf900 && rune <= 0xfaff) ||
          (rune >= 0xfe10 && rune <= 0xffef) ||
          rune >= 0x1f000) {
        _wideCharacters++;
      } else {
        _narrowCharacters++;
      }
    }
  }

  Duration elapsedAt(DateTime now) {
    final elapsed = (endedAt ?? now).difference(startedAt);
    return elapsed.isNegative ? Duration.zero : elapsed;
  }

  double? tokensPerSecondAt(DateTime now) {
    final milliseconds = elapsedAt(now).inMilliseconds;
    return milliseconds <= 0 || estimatedTokens == 0 ? null : estimatedTokens * 1000 / milliseconds;
  }
}

/// Reduces `session/update` + `_codeaw/event` messages into a conversation and the
/// session-level snapshots. The reference implementation is bridge/test/reduce.ts.
class Timeline extends ChangeNotifier {
  final items = <TimelineItem>[];
  final _byKey = <String, TimelineItem>{};
  final _dirty = <TimelineItem>{};
  List<TimelineItem> _rootItems = [];
  final _children = <String, List<TimelineItem>>{};
  final _parents = <String, ToolItem>{};
  final _agentStates = <String, ({int revision, Map state})>{};
  int _revision = 0;
  bool _hierarchyDirty = false;
  bool _structureChanged = false;
  bool _snapshotChanged = false;
  int _anon = 0;

  List<Map<String, dynamic>>? plan;
  List<Map<String, dynamic>> commands = const [];
  String? modeId;
  List<Map<String, dynamic>>? configOptions;
  Map<String, dynamic>? modes;
  Map<String, dynamic>? usage;
  String? title;
  String state = 'idle';
  int queued = 0;
  DateTime? turnStartedAt;
  TurnSummaryItem? currentTurn;
  TurnActivity _activity = TurnActivity.thinking;
  DateTime? _activityAt;
  final _activeTools = <ToolItem, DateTime>{};

  bool get running => state == 'running' || state == 'requires_action';
  ToolItem? get activeTool => _activeTools.keys.lastOrNull;
  TurnActivity get activity => activeTool == null ? _activity : TurnActivity.tool;

  /// Preserve the flat log for replay while presenting attributed child activity
  /// under its delegating tool. Missing parents stay visible at the root.
  List<TimelineItem> get rootItems {
    if (_hierarchyDirty) _rebuildHierarchy();
    return _rootItems;
  }

  List<TimelineItem> childrenOf(ToolItem tool) {
    if (_hierarchyDirty) _rebuildHierarchy();
    return _children[tool.toolCallId] ?? const [];
  }

  bool isSubagent(ToolItem tool) => tool.subagent != null || childrenOf(tool).isNotEmpty;

  List<ToolItem> get subagents => items.whereType<ToolItem>().where(isSubagent).toList();

  ToolItem? parentOf(TimelineItem item) {
    if (_hierarchyDirty) _rebuildHierarchy();
    return _parents[item.key];
  }

  Iterable<TimelineItem> descendantsOf(ToolItem tool) sync* {
    final pending = [...childrenOf(tool).reversed];
    while (pending.isNotEmpty) {
      final item = pending.removeLast();
      yield item;
      if (item is ToolItem) pending.addAll(childrenOf(item).reversed);
    }
  }

  TimelineItem? latestActivityOf(ToolItem tool) {
    TimelineItem? latest;
    for (final item in descendantsOf(tool)) {
      if (latest == null || item.activityRevision >= latest.activityRevision) latest = item;
    }
    return latest;
  }

  TimelineItem? currentActivityOf(ToolItem tool) {
    ToolItem? active;
    for (final item in descendantsOf(tool).whereType<ToolItem>()) {
      if (item.status != 'pending' && item.status != 'in_progress') continue;
      if (active == null || item.activityRevision >= active.activityRevision) active = item;
    }
    return active ?? latestActivityOf(tool);
  }

  SubagentStatus statusOfSubagent(ToolItem tool) {
    final info = tool.subagent;
    final descendants = descendantsOf(tool).toList();
    final lastActivity = descendants.fold(0, (latest, item) => item.activityRevision > latest ? item.activityRevision : latest);
    final reported = reportedSubagentStatus(tool.meta, tool.rawOutput);
    if (reported != null && reported != SubagentStatus.pending && reported != SubagentStatus.running && tool.lifecycleRevision >= lastActivity) {
      return reported;
    }
    if (tool.status == 'failed' && tool.statusRevision >= lastActivity) return SubagentStatus.failed;
    final active = descendants.whereType<ToolItem>().map((t) => subagentStatusOf(t.status));
    if (active.contains(SubagentStatus.running)) return SubagentStatus.running;
    if (active.contains(SubagentStatus.pending)) return SubagentStatus.running;
    final ids = info?.threadIds ?? <String>[];
    if (ids.any(_agentStates.containsKey)) {
      final states = [for (final id in ids) subagentStatusOf(_agentStates[id]?.state['status'])];
      for (final status in [SubagentStatus.running, SubagentStatus.pending, SubagentStatus.failed, SubagentStatus.cancelled, SubagentStatus.disconnected, SubagentStatus.unknown]) {
        if (states.contains(status)) return status;
      }
      return SubagentStatus.completed;
    }
    if (reported == SubagentStatus.running || reported == SubagentStatus.pending) return reported!;
    // A child can continue (or be resumed) after the launch RPC has returned.
    if (lastActivity > tool.statusRevision && tool.status == 'completed') return SubagentStatus.running;
    if (info?.background == true && tool.status == 'completed') return SubagentStatus.running;
    if (info?.launchOnly == true && tool.status == 'completed') return SubagentStatus.unknown;
    return subagentStatusOf(tool.status);
  }

  String? resultOfSubagent(ToolItem tool) {
    final messages = [for (final id in tool.subagent?.threadIds ?? <String>[])
      if (nonEmptyString(_agentStates[id]?.state['message']) case final String message) message];
    return messages.isEmpty ? null : messages.join('\n\n');
  }

  void _rebuildHierarchy() {
    _hierarchyDirty = false;
    _parents.clear();
    _children.clear();
    _rootItems = [];
    for (final item in items) {
      final candidate = item.parentToolCallId == null ? null : _byKey['tool:${item.parentToolCallId}'];
      ToolItem? parent = candidate is ToolItem ? candidate : null;
      TimelineItem? ancestor = parent;
      final seen = {item.key};
      while (ancestor != null) {
        if (!seen.add(ancestor.key)) { parent = null; break; }
        ancestor = ancestor.parentToolCallId == null ? null : _byKey['tool:${ancestor.parentToolCallId}'];
      }
      if (parent == null) {
        _rootItems.add(item);
      } else {
        _parents[item.key] = parent;
        (_children[parent.toolCallId] ??= []).add(item);
      }
    }
  }

  void _recordAgentStates(Map<String, dynamic> update, int revision) {
    final states = objectMap(objectMap(update['rawInput'])['agentsStates']);
    if (states.isEmpty) return;
    var changed = false;
    for (final entry in states.entries) {
      if (entry.key is! String || entry.value is! Map) continue;
      final previous = _agentStates[entry.key];
      if (previous != null && previous.revision > revision) continue;
      _agentStates[entry.key as String] = (revision: revision, state: entry.value as Map);
      changed = true;
    }
    if (changed) {
      for (final item in items.whereType<ToolItem>()) {
        if (item.subagent?.threadIds.any(states.containsKey) == true) _touch(item);
      }
    }
  }

  /// The bridge's start time survives replay, permission waits and queued prompts.
  /// Older bridges fall back to the time the running state was first observed.
  void setTurnState(String value, {num? startedAt, DateTime? observedAt, String? promptId}) {
    state = value;
    if (running) {
      turnStartedAt = startedAt != null
          ? DateTime.fromMillisecondsSinceEpoch(startedAt.toInt(), isUtc: true)
          : turnStartedAt ?? observedAt ?? DateTime.now();
      if (currentTurn == null || currentTurn!.startedAt != turnStartedAt) {
        final prompts = items.whereType<MessageItem>().where((m) => m.role == MessageRole.user && m.parentToolCallId == null);
        final prompt = promptId == null
            ? prompts.where((m) => !m.steered && (!m.queued || m.dequeued == 'started')).lastOrNull
            : prompts.where((m) => m.promptId == promptId).lastOrNull;
        currentTurn = TurnSummaryItem('turn:${promptId ?? prompt?.promptId ?? turnStartedAt!.millisecondsSinceEpoch}', startedAt: turnStartedAt!, prompt: prompt);
      }
      _activeTools.removeWhere((_, at) => at.isBefore(turnStartedAt!));
      if (_activityAt == null || _activityAt!.isBefore(turnStartedAt!)) {
        _activity = TurnActivity.thinking;
        _activityAt = null;
      }
    } else {
      turnStartedAt = null;
      currentTurn = null;
      _activity = TurnActivity.thinking;
      _activityAt = null;
      _activeTools.clear();
    }
    _snapshotChanged = true;
  }

  void _recordActivity(TurnActivity value, DateTime at) {
    if (turnStartedAt != null && at.isBefore(turnStartedAt!)) return;
    if (_activity != value) _snapshotChanged = true;
    _activity = value;
    _activityAt = at;
  }

  void addPendingPrompt(String promptId, List<Map<String, dynamic>> blocks) {
    final mid = 'u-$promptId';
    final item = _upsert('user_message_chunk:$mid', () => MessageItem('user_message_chunk:$mid', MessageRole.user, mid));
    item.promptId = promptId;
    item.parts.addAll(blocks.map(Map<String, dynamic>.of));
    item.receipt = 'sending';
    item.optimistic = true;
    _touch(item);
    flush();
  }

  void clear({bool preserveUnconfirmed = false}) {
    final unconfirmed = preserveUnconfirmed ? items.whereType<MessageItem>().where((m) => m.optimistic).toList() : <MessageItem>[];
    items.clear();
    _byKey.clear();
    _dirty.clear();
    _rootItems = [];
    _children.clear();
    _parents.clear();
    _agentStates.clear();
    _detachedPromptEvents.clear();
    _revision = 0;
    _hierarchyDirty = false;
    plan = null;
    commands = const [];
    modeId = null;
    usage = null;
    title = null;
    queued = 0;
    setTurnState('idle');
    _structureChanged = true;
    _snapshotChanged = true;
    for (final item in unconfirmed) {
      _byKey[item.key] = item;
      _add(item);
      _touch(item);
    }
  }

  /// Keep uncertain local sends after the authoritative history on a full replay.
  void finishReplay() {
    final unconfirmed = items.whereType<MessageItem>().where((m) => m.optimistic).toList();
    if (unconfirmed.isEmpty) return;
    items.removeWhere((item) => unconfirmed.contains(item));
    items.addAll(unconfirmed);
    _hierarchyDirty = _structureChanged = true;
  }

  /// Commit a complete replay without making the visible list empty in between.
  void replaceWith(Timeline source, {bool preserveUnconfirmed = true}) {
    final uncertain = preserveUnconfirmed
        ? items
              .whereType<MessageItem>()
              .where((m) => m.optimistic && !source._byKey.containsKey(m.key))
              .toList()
        : <MessageItem>[];
    items
      ..clear()
      ..addAll(source.items)
      ..addAll(uncertain);
    _byKey
      ..clear()
      ..addAll(source._byKey);
    for (final item in uncertain) {
      _byKey[item.key] = item;
    }
    _dirty.clear();
    _agentStates
      ..clear()
      ..addAll(source._agentStates);
    _detachedPromptEvents
      ..clear()
      ..addAll(source._detachedPromptEvents);
    // A removed uncertain send may have only a tombstone in the new epoch.
    for (final message in uncertain) {
      for (final event in _detachedPromptEvents.remove(message.promptId) ?? const <Map<String, dynamic>>[]) {
        _applyEvent(event, DateTime.now());
      }
    }
    _revision = source._revision;
    _anon = source._anon;
    plan = source.plan;
    commands = source.commands;
    modeId = source.modeId;
    configOptions = source.configOptions;
    modes = source.modes;
    usage = source.usage;
    title = source.title;
    state = source.state;
    queued = source.queued;
    turnStartedAt = source.turnStartedAt;
    currentTurn = source.currentTurn;
    _activity = source._activity;
    _activityAt = source._activityAt;
    _activeTools
      ..clear()
      ..addAll(source._activeTools);
    _hierarchyDirty = _structureChanged = _snapshotChanged = true;
    finishReplay();
    flush();
  }

  /// A reduced, versioned snapshot: streaming chunks are already folded, with
  /// turn references and collaboration ordering retained for offline display.
  Map<String, dynamic> toSnapshot() {
    Map<String, dynamic> turn(TurnSummaryItem t) => {
      'key': t.key,
      'startedAt': t.startedAt.millisecondsSinceEpoch,
      'endedAt': t.endedAt?.millisecondsSinceEpoch,
      'prompt': t.prompt?.key,
      'messages': t.messages.map((m) => m.key).toList(),
      'steered': t.steeredPrompts.map((m) => m.key).toList(),
      'narrow': t._narrowCharacters,
      'wide': t._wideCharacters,
    };
    return {
      'version': 1,
      'items': [
        for (final i in items)
          {
            'key': i.key,
            'parent': i.parentToolCallId,
            'revision': i.activityRevision,
            ...switch (i) {
              MessageItem m => {
                'type': 'message',
                'role': m.role.name,
                'mid': m.mid,
                'parts': m.parts,
                'promptId': m.promptId,
                'queued': m.queued,
                'steered': m.steered,
                'receipt': m.receipt,
                'optimistic': m.optimistic,
                'removed': m.removed,
                'dequeued': m.dequeued,
              },
              ToolItem t => {
                'type': 'tool',
                'id': t.toolCallId,
                'title': t.title,
                'kind': t.kind,
                'status': t.status,
                'name': t.name,
                'content': t.content,
                'locations': t.locations,
                'rawInput': t.rawInput,
                'rawOutput': t.rawOutput,
                'terminalOutput': t.terminalOutput,
                'terminalId': t.terminalId,
                'meta': t.meta,
                'statusRevision': t.statusRevision,
                'lifecycleRevision': t.lifecycleRevision,
                'deferredSeq': t.deferredSeq,
                'hydratedThroughSeq': t.hydratedThroughSeq,
                'deferredDiff': t.deferredDiff,
                'deferredExitCode': t.deferredExitCode,
              },
              PermissionItem p => {
                'type': 'permission',
                'id': p.requestId,
                'toolCall': p.toolCall,
                'options': p.options,
                'outcome': p.outcome,
                'optionName': p.optionName,
                'by': p.by,
              },
              ElicitationItem e => {
                'type': 'elicitation',
                'id': e.requestId,
                'request': e.request,
                'action': e.action,
                'by': e.by,
              },
              NoticeItem n => {
                'type': 'notice',
                'severity': n.severity,
                'title': n.title,
                'description': n.description,
              },
              ErrorItem e => {'type': 'error', 'message': e.message},
              StopItem s => {'type': 'stop', 'reason': s.stopReason},
              TurnSummaryItem _ => {'type': 'turn'},
              _ => throw StateError('Unknown timeline item'),
            },
          },
      ],
      'turns': [
        for (final t in items.whereType<TurnSummaryItem>()) turn(t),
        if (currentTurn != null && !items.contains(currentTurn))
          turn(currentTurn!),
      ],
      'currentTurn': currentTurn?.key,
      'agentStates': {
        for (final e in _agentStates.entries)
          e.key: {'revision': e.value.revision, 'state': e.value.state},
      },
      'detachedPromptEvents': {
        for (final e in _detachedPromptEvents.entries) e.key: e.value.toList(),
      },
      'revision': _revision,
      'anon': _anon,
      'plan': plan,
      'commands': commands,
      'modeId': modeId,
      'configOptions': configOptions,
      'modes': modes,
      'usage': usage,
      'title': title,
      'state': state,
      'queued': queued,
      'turnStartedAt': turnStartedAt?.millisecondsSinceEpoch,
      'activity': _activity.name,
      'activityAt': _activityAt?.millisecondsSinceEpoch,
      'activeTools': {
        for (final e in _activeTools.entries)
          e.key.key: e.value.millisecondsSinceEpoch,
      },
    };
  }

  factory Timeline.fromSnapshot(Map<String, dynamic> s) {
    if (s['version'] != 1) {
      throw const FormatException('Unsupported history cache');
    }
    final timeline = Timeline();
    List<Map<String, dynamic>> maps(dynamic v) => (v as List? ?? const [])
        .map((m) => Map<String, dynamic>.from(m as Map))
        .toList();
    Map<String, dynamic>? map(dynamic v) =>
        v == null ? null : Map<String, dynamic>.from(v as Map);
    DateTime? time(dynamic v) => v == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch((v as num).toInt(), isUtc: true);
    final rows = maps(s['items']);
    for (final j in rows) {
      final key = j['key'] as String;
      final TimelineItem item;
      switch (j['type']) {
        case 'message':
          item =
              MessageItem(
                  key,
                  MessageRole.values.byName(j['role'] as String),
                  j['mid'] as String,
                )
                ..parts.addAll(maps(j['parts']))
                ..promptId = j['promptId'] as String?
                ..queued = j['queued'] == true
                ..steered = j['steered'] == true
                ..receipt = j['receipt'] as String?
                ..optimistic = j['optimistic'] == true
                ..removed = j['removed'] == true
                ..dequeued = j['dequeued'] as String?;
        case 'tool':
          item = ToolItem(key, j['id'] as String)
            ..title = j['title'] as String?
            ..kind = j['kind'] as String?
            ..status = j['status'] as String?
            ..name = j['name'] as String?
            ..content = j['content'] == null ? null : maps(j['content'])
            ..locations = j['locations'] == null ? null : maps(j['locations'])
            ..rawInput = j['rawInput']
            ..rawOutput = j['rawOutput']
            ..terminalOutput = j['terminalOutput'] as String? ?? ''
            ..terminalId = j['terminalId'] as String?
            ..meta.addAll(map(j['meta']) ?? const {})
            ..statusRevision = (j['statusRevision'] as num?)?.toInt() ?? 0
            ..lifecycleRevision = (j['lifecycleRevision'] as num?)?.toInt() ?? 0
            ..deferredSeq = (j['deferredSeq'] as num?)?.toInt()
            ..hydratedThroughSeq = (j['hydratedThroughSeq'] as num?)?.toInt() ?? 0
            ..deferredDiff = j['deferredDiff'] == true
            ..deferredExitCode = (j['deferredExitCode'] as num?)?.toInt();
        case 'permission':
          item = PermissionItem(key, j['id'] as String)
            ..toolCall = map(j['toolCall'])
            ..options = maps(j['options'])
            ..outcome = map(j['outcome'])
            ..optionName = j['optionName'] as String?
            ..by = j['by'] as String?;
        case 'elicitation':
          item = ElicitationItem(key, j['id'] as String)
            ..request = map(j['request'])
            ..action = j['action'] as String?
            ..by = j['by'] as String?;
        case 'notice':
          item = NoticeItem(
            key,
            j['severity'] as String,
            j['title'] as String,
            j['description'] as String?,
          );
        case 'error':
          item = ErrorItem(key, j['message'] as String);
        case 'stop':
          item = StopItem(key, j['reason'] as String);
        case 'turn':
          continue; // Resolve references after all messages exist.
        default:
          throw const FormatException('Invalid history item');
      }
      item.parentToolCallId = j['parent'] as String?;
      item.activityRevision = (j['revision'] as num?)?.toInt() ?? 0;
      timeline._byKey[key] = item;
    }
    MessageItem? message(dynamic key) => timeline._byKey[key] as MessageItem?;
    for (final j in maps(s['turns'])) {
      final t =
          TurnSummaryItem(
              j['key'] as String,
              startedAt: time(j['startedAt'])!,
              prompt: message(j['prompt']),
            )
            ..endedAt = time(j['endedAt'])
            ..messages.addAll(
              (j['messages'] as List).map(message).whereType<MessageItem>(),
            )
            ..steeredPrompts.addAll(
              (j['steered'] as List).map(message).whereType<MessageItem>(),
            )
            .._narrowCharacters = (j['narrow'] as num).toInt()
            .._wideCharacters = (j['wide'] as num).toInt();
      timeline._byKey[t.key] = t;
    }
    for (final j in rows) {
      timeline.items.add(timeline._byKey[j['key']]!);
    }
    for (final e in (map(s['agentStates']) ?? const {}).entries) {
      final value = e.value as Map;
      timeline._agentStates[e.key] = (
        revision: (value['revision'] as num).toInt(),
        state: value['state'] as Map,
      );
    }
    for (final e in (map(s['detachedPromptEvents']) ?? const {}).entries) {
      timeline._detachedPromptEvents[e.key] = maps(e.value);
    }
    timeline
      .._revision = (s['revision'] as num).toInt()
      .._anon = (s['anon'] as num).toInt()
      ..plan = s['plan'] == null ? null : maps(s['plan'])
      ..commands = maps(s['commands'])
      ..modeId = s['modeId'] as String?
      ..configOptions = s['configOptions'] == null
          ? null
          : maps(s['configOptions'])
      ..modes = map(s['modes'])
      ..usage = map(s['usage'])
      ..title = s['title'] as String?
      ..state = s['state'] as String? ?? 'idle'
      ..queued = (s['queued'] as num?)?.toInt() ?? 0
      ..turnStartedAt = time(s['turnStartedAt'])
      ..currentTurn = timeline._byKey[s['currentTurn']] as TurnSummaryItem?
      .._activity = TurnActivity.values.byName(s['activity'] as String)
      .._activityAt = time(s['activityAt'])
      .._hierarchyDirty = true;
    for (final e in (map(s['activeTools']) ?? const {}).entries) {
      final tool = timeline._byKey[e.key];
      if (tool is ToolItem) timeline._activeTools[tool] = time(e.value)!;
    }
    return timeline;
  }

  Timeline({this.anonScope = ''});

  /// Keeps generated keys of separately reduced history pages distinct.
  final String anonScope;

  /// Prompt receipts whose message is in a history page that is not loaded yet.
  final _detachedPromptEvents = <String, List<Map<String, dynamic>>>{};

  /// Puts an older page of a paged replay before the loaded history.
  ///
  /// The bridge sends a page in order with live updates, so the page reflects
  /// everything applied here before it. Its copy of an item that is also loaded
  /// (a long-running tool or a message that kept streaming) replaces the partial
  /// one; requests keep a resolution that arrived in a newer page.
  void prependHistory(Timeline older) {
    // Loaded item → the page's complete copy that takes its place.
    final replaced = <TimelineItem, TimelineItem>{};
    final head = <TimelineItem>[];
    for (final item in older.items) {
      final existing = _byKey[item.key];
      if (existing is TurnSummaryItem) continue;
      if (existing is MessageItem && item is MessageItem) {
        item.removed = item.removed || existing.removed;
        item.dequeued = existing.dequeued ?? item.dequeued;
        if (existing.receipt == 'read' || item.receipt != 'read') item.receipt = existing.receipt ?? item.receipt;
      } else if (existing is PermissionItem && item is PermissionItem) {
        item.toolCall ??= existing.toolCall;
        if (item.options.isEmpty) item.options = existing.options;
        if (existing.resolved) {
          item
            ..outcome = existing.outcome
            ..optionName = existing.optionName
            ..by = existing.by;
        }
      } else if (existing is ElicitationItem && item is ElicitationItem) {
        item.request ??= existing.request;
        if (existing.resolved) {
          item
            ..action = existing.action
            ..by = existing.by;
        }
      }
      if (existing != null) replaced[existing] = item;
      _byKey[item.key] = item;
      head.add(item);
    }
    final rest = [for (final item in items) if (!replaced.containsKey(item)) item];
    items
      ..clear()
      ..addAll(head)
      ..addAll(rest);
    for (final turn in {...items.whereType<TurnSummaryItem>(), ?currentTurn}) {
      for (final list in [turn.messages, turn.steeredPrompts]) {
        for (var i = 0; i < list.length; i++) {
          if (replaced[list[i]] case final MessageItem next) list[i] = next;
        }
      }
    }
    // A turn split across pages: the page saw its start, the loaded history its end.
    final start = older.currentTurn;
    final end = start == null ? null : (currentTurn?.key == start.key ? currentTurn : _byKey[start.key]);
    if (start != null && end is TurnSummaryItem) {
      final joined = TurnSummaryItem(end.key, startedAt: start.startedAt, prompt: start.prompt ?? end.prompt)
        ..endedAt = end.endedAt
        ..messages.addAll({...start.messages, ...end.messages})
        ..steeredPrompts.addAll({...start.steeredPrompts, ...end.steeredPrompts})
        .._narrowCharacters = start._narrowCharacters + end._narrowCharacters
        .._wideCharacters = start._wideCharacters + end._wideCharacters;
      if (identical(currentTurn, end)) currentTurn = joined;
      final index = items.indexOf(end);
      if (index >= 0) {
        items[index] = joined;
        _byKey[end.key] = joined;
      }
    }
    for (final MapEntry(key: tool, value: at) in [..._activeTools.entries]) {
      if (replaced[tool] case final ToolItem next) {
        _activeTools.remove(tool);
        if (next.status == 'pending' || next.status == 'in_progress') _activeTools[next] = at;
      }
    }
    for (final MapEntry(:key, :value) in older._agentStates.entries) {
      final known = _agentStates[key];
      if (known == null || known.revision < value.revision) _agentStates[key] = value;
    }
    if (older._revision > _revision) _revision = older._revision;
    for (final MapEntry(:key, :value) in older._detachedPromptEvents.entries) {
      (_detachedPromptEvents[key] ??= []).insertAll(0, value);
    }
    for (final message in older.items.whereType<MessageItem>()) {
      for (final event in _detachedPromptEvents.remove(message.promptId) ?? const <Map<String, dynamic>>[]) {
        _applyEvent(event, DateTime.now());
      }
    }
    _hierarchyDirty = _structureChanged = _snapshotChanged = true;
    flush();
  }

  T _upsert<T extends TimelineItem>(String key, T Function() make) {
    final existing = _byKey[key];
    if (existing is T) return existing;
    final item = make();
    _byKey[key] = item;
    items.add(item);
    _hierarchyDirty = true;
    _structureChanged = true;
    return item;
  }

  void _add(TimelineItem item) {
    items.add(item);
    _hierarchyDirty = true;
    _structureChanged = true;
  }

  void _touch(TimelineItem item) {
    item.markDirty();
    _dirty.add(item);
  }

  /// Applies one message. Returns true if it was understood.
  bool apply(String method, Map<String, dynamic> params) {
    final timestamp = (((params['_meta'] as Map?)?['codeaw'] as Map?)?['t'] as num?)?.toInt();
    final at = timestamp == null ? DateTime.now() : DateTime.fromMillisecondsSinceEpoch(timestamp, isUtc: true);
    if (method == 'session/update') {
      final u = params['update'];
      final seq = (((params['_meta'] as Map?)?['codeaw'] as Map?)?['seq'] as num?)?.toInt();
      if (seq != null && seq > _revision) _revision = seq;
      if (u is Map<String, dynamic>) _applyUpdate(u, at, seq ?? ++_revision);
      return true;
    }
    if (method == '_codeaw/event') {
      final e = params['event'];
      if (e is Map<String, dynamic>) _applyEvent(e, at);
      return true;
    }
    return false;
  }

  void _applyUpdate(Map<String, dynamic> u, DateTime at, int revision) {
    final type = u['sessionUpdate'];
    switch (type) {
      case 'user_message_chunk' || 'agent_message_chunk' || 'agent_thought_chunk':
        final codeaw = (u['_meta'] is Map ? (u['_meta'] as Map)['codeaw'] : null) as Map?;
        final mid = '${codeaw?['mid'] ?? 'anon$anonScope${_anon++}'}';
        final role = type == 'user_message_chunk'
            ? MessageRole.user
            : type == 'agent_thought_chunk'
                ? MessageRole.thought
                : MessageRole.agent;
        if (role != MessageRole.user) {
          _recordActivity(role == MessageRole.thought ? TurnActivity.thinking : TurnActivity.responding, at);
        }
        final parent = subagentParentId(u['_meta']);
        final promptId = role == MessageRole.user ? (codeaw?['promptId'] as String?) : null;
        final key = parent == null ? '$type:${promptId == null ? mid : 'u-$promptId'}' : '$type:subagent:${parent.length}:$parent:$mid';
        final item = _upsert(key, () => MessageItem(key, role, mid));
        if (item.parentToolCallId != parent) _hierarchyDirty = _structureChanged = true;
        item.parentToolCallId = parent;
        item.activityRevision = revision;
        if (codeaw != null) {
          item.promptId ??= codeaw['promptId'] as String?;
          if (codeaw['queued'] is bool) item.queued = codeaw['queued'] as bool;
          if (codeaw['steered'] is bool) item.steered = codeaw['steered'] as bool;
          if (codeaw['receipt'] == 'read') item.receipt = 'read';
          if (codeaw['replace'] == true && codeaw['partIndex'] == 0) item.parts.clear();
        }
        final content = u['content'];
        if (content is Map<String, dynamic>) {
          if (item.optimistic) {
            item.parts.clear();
            item.optimistic = false;
            items.remove(item);
            items.add(item);
            _hierarchyDirty = _structureChanged = true;
          }
          final last = item.parts.isEmpty ? null : item.parts.last;
          if (content['type'] == 'text' && last != null && last['type'] == 'text') {
            last['text'] = '${last['text'] ?? ''}${content['text'] ?? ''}';
          } else {
            item.parts.add(Map<String, dynamic>.of(content));
          }
          final turn = currentTurn;
          if (turn != null) {
            if (role != MessageRole.user && parent == null) {
              if (!turn.messages.contains(item)) turn.messages.add(item);
              if (content['type'] == 'text') turn.recordText(content['text'] as String? ?? '');
            } else if (item.steered && !turn.steeredPrompts.contains(item)) {
              turn.steeredPrompts.add(item);
            }
          }
        }
        _touch(item);
      case 'tool_call' || 'tool_call_update':
        final before = (activeTool, activeTool?.title, activeTool?.displayTitle, activeTool?.kind, activity);
        final id = '${u['toolCallId']}';
        final item = _upsert('tool:$id', () => ToolItem('tool:$id', id));
        // Hydration may arrive ahead of pending WebSocket notifications.
        if (revision <= item.hydratedThroughSeq) return;
        final oldParent = item.parentToolCallId;
        final wasSubagent = item.subagent != null;
        item.merge(u);
        if (wasSubagent != (item.subagent != null)) _snapshotChanged = true;
        item.activityRevision = revision;
        final codeaw = objectMap(objectMap(u['_meta'])['codeaw']);
        if (u['status'] is String) item.statusRevision = (codeaw['toolStatusSeq'] as num?)?.toInt() ?? revision;
        if (reportedSubagentStatus(u['_meta'], u['rawOutput']) != null) {
          item.lifecycleRevision = (codeaw['toolLifecycleSeq'] as num?)?.toInt() ?? revision;
        }
        if (oldParent != item.parentToolCallId) _hierarchyDirty = _structureChanged = true;
        _dirty.add(item);
        final statesRevision = objectMap(objectMap(u['_meta'])['codeaw'])['agentStatesSeq'];
        _recordAgentStates(u, statesRevision is num ? statesRevision.toInt() : revision);
        if (turnStartedAt == null || !at.isBefore(turnStartedAt!)) {
          if (item.status == 'pending' || item.status == 'in_progress') {
            _activeTools.putIfAbsent(item, () => at);
          } else if (_activeTools.remove(item) != null && _activeTools.isEmpty) {
            _recordActivity(TurnActivity.thinking, at);
          }
        }
        if (before != (activeTool, activeTool?.title, activeTool?.displayTitle, activeTool?.kind, activity)) _snapshotChanged = true;
      case 'plan':
        plan = (u['entries'] as List?)?.whereType<Map<String, dynamic>>().toList();
        _snapshotChanged = true;
      case 'available_commands_update':
        commands = (u['availableCommands'] as List?)?.whereType<Map<String, dynamic>>().toList() ?? const [];
        _snapshotChanged = true;
      case 'current_mode_update':
        modeId = u['currentModeId'] as String?;
        if (modes != null) modes = {...modes!, 'currentModeId': modeId};
        _snapshotChanged = true;
      case 'config_option_update':
        configOptions = (u['configOptions'] as List?)?.whereType<Map<String, dynamic>>().toList();
        _snapshotChanged = true;
      case 'usage_update':
        usage = {'used': u['used'], 'size': u['size'], 'cost': u['cost']};
        _snapshotChanged = true;
      case 'session_info_update':
        if (u.containsKey('title')) title = u['title'] as String?;
        _snapshotChanged = true;
      case 'notice':
        _add(NoticeItem('notice:$anonScope${_anon++}', '${u['severity'] ?? 'info'}', '${u['title'] ?? ''}', u['description'] as String?));
    }
  }

  void _applyEvent(Map<String, dynamic> e, DateTime at) {
    switch (e['type']) {
      case 'state':
        final completed = e['completedTurn'] as Map?;
        var turn = currentTurn;
        if (e['state'] == 'idle' && completed != null && turn == null) {
          final promptId = completed['promptId'] as String?;
          final prompt = items.whereType<MessageItem>().where((m) => m.role == MessageRole.user && m.parentToolCallId == null && m.promptId == promptId).lastOrNull;
          turn = TurnSummaryItem(
            'turn:$promptId',
            startedAt: DateTime.fromMillisecondsSinceEpoch((completed['startedAt'] as num).toInt(), isUtc: true),
            prompt: prompt,
          );
        }
        setTurnState('${e['state'] ?? 'idle'}', startedAt: e['turnStartedAt'] as num?, observedAt: at, promptId: e['turnPromptId'] as String?);
        queued = (e['queued'] as num?)?.toInt() ?? 0;
        final stop = e['stopReason'];
        if (state == 'idle' && stop is String && stop != 'end_turn') _add(StopItem('stop:$anonScope${_anon++}', stop));
        if (state == 'idle' && turn != null && (stop != null || completed != null)) {
          turn.endedAt = completed?['endedAt'] is num
              ? DateTime.fromMillisecondsSinceEpoch((completed!['endedAt'] as num).toInt(), isUtc: true)
              : at;
          if (!_byKey.containsKey(turn.key)) {
            _byKey[turn.key] = turn;
            _add(turn);
          }
        }
        _snapshotChanged = true;
      case 'permission_request':
        final id = '${e['requestId']}';
        final item = _upsert('perm:$id', () => PermissionItem('perm:$id', id));
        item.toolCall = e['toolCall'] as Map<String, dynamic>?;
        item.options = (e['options'] as List?)?.whereType<Map<String, dynamic>>().toList() ?? const [];
        _touch(item);
      case 'permission_resolved':
        final id = '${e['requestId']}';
        final item = _upsert('perm:$id', () => PermissionItem('perm:$id', id));
        item.outcome = e['outcome'] as Map<String, dynamic>? ?? const {'outcome': 'cancelled'};
        item.optionName = e['optionName'] as String?;
        item.by = e['by'] as String?;
        _touch(item);
      case 'elicitation_request':
        final id = '${e['requestId']}';
        final item = _upsert('elicit:$id', () => ElicitationItem('elicit:$id', id));
        item.request = e['request'] as Map<String, dynamic>?;
        _touch(item);
      case 'elicitation_resolved':
        final id = '${e['requestId']}';
        final item = _upsert('elicit:$id', () => ElicitationItem('elicit:$id', id));
        item.action = '${e['action'] ?? 'cancel'}';
        item.by = e['by'] as String?;
        _touch(item);
      case 'error':
        _add(ErrorItem('error:$anonScope${_anon++}', '${e['message'] ?? 'Error'}'));
      case 'dequeued':
        final mid = 'u-${e['promptId']}';
        final item = _byKey['user_message_chunk:$mid'];
        if (item is MessageItem) {
          item.dequeued = e['cancelled'] == true ? 'cancelled' : 'started';
          if (e['removed'] == true) {
            item.removed = true;
            item.optimistic = false;
            _structureChanged = _snapshotChanged = true;
          }
          _touch(item);
        } else {
          (_detachedPromptEvents['${e['promptId']}'] ??= []).add(e);
          _snapshotChanged = true;
        }
      case 'prompt_receipt':
        final mid = 'u-${e['promptId']}';
        final item = _byKey['user_message_chunk:$mid'];
        // Older desktop epochs can contain receipts without a correlated message.
        // Do not fabricate an empty user bubble for those historic ids; the
        // message may also be in a history page that is loaded later.
        if (item is! MessageItem) {
          (_detachedPromptEvents['${e['promptId']}'] ??= []).add(e);
          _snapshotChanged = true;
          return;
        }
        item.promptId = e['promptId'] as String?;
        final status = e['status'] as String?;
        if (item.receipt != 'read' || status == 'read') item.receipt = status;
        if (status == 'read' && item.queued) item.dequeued = 'started';
        _touch(item);
    }
  }

  /// Notifies item and list listeners for everything applied since the last flush.
  void flush() {
    if (_hierarchyDirty) {
      _rebuildHierarchy();
      _structureChanged = true;
    }
    // A collapsed parent still reflects the latest child status and activity.
    for (final item in _dirty.toList()) {
      var parent = _parents[item.key];
      while (parent != null) {
        _touch(parent);
        parent = _parents[parent.key];
      }
    }
    for (final item in _dirty) {
      item.flush();
    }
    _dirty.clear();
    if (_structureChanged || _snapshotChanged) {
      _structureChanged = false;
      _snapshotChanged = false;
      notifyListeners();
    }
  }

  /// A comparable snapshot (used by tests to check replay equivalence).
  @visibleForTesting
  Map<String, Object?> debugSnapshot() => {
        'items': [
          for (final i in items)
            switch (i) {
              MessageItem m => {'k': m.key, 'parts': m.parts, 'dequeued': m.dequeued},
              ToolItem t => {
                  'k': t.key,
                  'title': t.title,
                  'status': t.status,
                  'kind': t.kind,
                  'content': t.content,
                  'out': t.terminalOutput,
                  'exit': t.exitCode,
                },
              PermissionItem p => {'k': p.key, 'outcome': p.outcome, 'by': p.by, 'title': p.title},
              ElicitationItem e => {'k': e.key, 'action': e.action},
              NoticeItem n => {'notice': n.title},
              ErrorItem e => {'error': e.message},
              StopItem s => {'stop': s.stopReason},
              TurnSummaryItem t => {'k': t.key, 'response': t.responseText, 'tokens': t.estimatedTokens},
              _ => {'k': i.key},
            },
        ],
        'plan': plan,
        'commands': commands.length,
        'modeId': modeId,
        'configOptions': configOptions,
        'usage': usage,
        'title': title,
        'state': state,
      };
}
