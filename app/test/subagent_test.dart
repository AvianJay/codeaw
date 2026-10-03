import 'dart:io';

import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/session_controller.dart';
import 'package:codeaw/data/subagent.dart';
import 'package:codeaw/data/timeline.dart';
import 'package:codeaw/ui/chat/items.dart';
import 'package:codeaw/ui/chat/subagent_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void update(Timeline timeline, Map<String, dynamic> data, {int? seq}) {
  timeline.apply('session/update', {
    'update': data,
    if (seq != null)
      '_meta': {
        'codeaw': {'seq': seq},
      },
  });
  timeline.flush();
}

Map<String, dynamic> delegation(String id, {String? parent, String status = 'in_progress'}) => {
  'sessionUpdate': 'tool_call',
  'toolCallId': id,
  'kind': 'other',
  'status': status,
  'title': '檢查聊天介面',
  'rawInput': {'description': '檢查聊天介面', 'prompt': '檢查手機版排版與工具狀態，整理需要調整的地方。', 'subagent_type': 'Explore', 'model': 'sonnet'},
  '_meta': {
    'claudeCode': {'toolName': 'Agent', 'parentToolUseId': ?parent},
  },
};

Map<String, dynamic> message(String text, {String? parent, String mid = 'same'}) => {
  'sessionUpdate': 'agent_message_chunk',
  'content': {'type': 'text', 'text': text},
  '_meta': {
    'codeaw': {'mid': mid},
    if (parent != null) 'claudeCode': {'parentToolUseId': parent},
  },
};

ToolItem tool(Timeline t, String id) => t.items.whereType<ToolItem>().firstWhere((item) => item.toolCallId == id);

SessionController controller() {
  final client = BridgeClient(HostConfig(name: 'test', urls: ['ws://localhost:1'], token: 'test', deviceId: 'test', deviceName: 'test'));
  return SessionController(client, 'claude:test');
}

Widget conversation(SessionController c, {Brightness brightness = Brightness.light, double textScale = 1}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: ThemeData(
    colorSchemeSeed: const Color(0xFF0F9D8A),
    brightness: brightness,
    fontFamily: 'Roboto',
    fontFamilyFallback: const ['NotoSansTC'],
  ),
  home: Scaffold(
    appBar: AppBar(title: const Text('子代理活動')),
    body: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: ListenableBuilder(
        listenable: c.timeline,
        builder: (context, _) => ListView(
          children: [
            for (final item in c.timeline.rootItems) TimelineItemView(key: ValueKey(item.key), item: item, controller: c, isLast: false),
          ],
        ),
      ),
    ),
  ),
);

void demo(Timeline t) {
  t.setTurnState('running');
  update(t, delegation('agent'));
  update(t, {
    'sessionUpdate': 'tool_call',
    'toolCallId': 'read',
    'title': '讀取 chat_page.dart',
    'kind': 'read',
    'status': 'completed',
    '_meta': {
      'claudeCode': {'parentToolUseId': 'agent'},
    },
  });
  update(t, message('手機版的工具卡片排版正常，正在確認並行任務的更新。', parent: 'agent'));
  update(t, {
    'sessionUpdate': 'tool_call',
    'toolCallId': 'test',
    'title': 'flutter test',
    'kind': 'execute',
    'status': 'in_progress',
    '_meta': {
      'claudeCode': {'parentToolUseId': 'agent'},
    },
  });
}

void main() {
  test('identifies delegation from adapter fields without classifying ordinary tasks', () {
    expect(SubagentInfo.fromTool(name: 'Task', input: {'description': 'Audit'})?.name, 'Audit');
    expect(
      SubagentInfo.fromTool(
        title: 'spawnAgent',
        input: {
          'prompt': 'Audit',
          'receiverThreadIds': ['child'],
        },
      )?.launchOnly,
      isTrue,
    );
    expect(
      SubagentInfo.fromTool(
        title: 'Start subagent test',
        input: {'agentThreadId': 'id', 'agentPath': '/root/test', 'activityKind': 'started'},
      )?.name,
      'test',
    );
    expect(SubagentInfo.fromTool(title: 'Write subagent docs', input: {'command': 'cat Task.md'}), isNull);
    expect(SubagentInfo.fromTool(name: 'TaskOutput', input: {'task_id': 'x'}), isNull);
  });

  test('groups out-of-order children, preserves metadata on updates and notifies ancestors', () {
    final t = Timeline();
    addTearDown(t.dispose);
    update(t, message('Child', parent: 'agent'));
    expect(t.rootItems, hasLength(1));
    update(t, delegation('agent'));
    final parent = tool(t, 'agent');
    expect(t.rootItems, [parent]);
    expect(t.childrenOf(parent).single, isA<MessageItem>());
    var notifications = 0;
    parent.addListener(() => notifications++);
    update(t, {
      'sessionUpdate': 'tool_call',
      'toolCallId': 'read',
      'title': 'Read file',
      'status': 'in_progress',
      '_meta': {
        'claudeCode': {'parentToolUseId': 'agent'},
      },
    });
    update(t, {'sessionUpdate': 'tool_call_update', 'toolCallId': 'read', 'status': 'completed'});
    expect(t.childrenOf(parent), hasLength(2));
    expect(tool(t, 'read').parentToolCallId, 'agent');
    expect(notifications, 2);
    t.clear();
    expect(t.rootItems, isEmpty);
    expect(t.childrenOf(parent), isEmpty);
  });

  test('separates parallel child messages sharing IDs and excludes them from the parent answer', () {
    final t = Timeline()..setTurnState('running');
    addTearDown(t.dispose);
    update(t, delegation('a'));
    update(t, delegation('b'));
    update(t, message('Main'));
    update(t, message('A', parent: 'a'));
    update(t, message('B', parent: 'b'));
    update(t, message(' continues', parent: 'a'));
    expect(t.rootItems, hasLength(3));
    expect((t.childrenOf(tool(t, 'a')).single as MessageItem).text, 'A continues');
    expect((t.childrenOf(tool(t, 'b')).single as MessageItem).text, 'B');
    expect(t.currentTurn!.responseText, 'Main');
  });

  test('child user messages never become the next main-turn prompt', () {
    final t = Timeline();
    addTearDown(t.dispose);
    update(t, {...message('Main prompt'), 'sessionUpdate': 'user_message_chunk'});
    update(t, {...message('Delegated prompt', parent: 'a'), 'sessionUpdate': 'user_message_chunk'});
    t.setTurnState('running');
    expect(t.currentTurn!.prompt!.text, 'Main prompt');
  });

  test('handles nested agents, missing parents and malformed cycles without hiding activity', () {
    final t = Timeline();
    addTearDown(t.dispose);
    update(t, delegation('root'));
    update(t, delegation('nested', parent: 'root'));
    update(t, message('Nested output', parent: 'nested'));
    update(t, message('Unknown owner', parent: 'missing'));
    expect(t.rootItems, hasLength(2));
    expect(t.childrenOf(tool(t, 'root')).single, tool(t, 'nested'));
    update(t, delegation('a', parent: 'b'));
    update(t, delegation('b', parent: 'a'));
    update(t, delegation('self', parent: 'self'));
    expect(t.rootItems, containsAll([tool(t, 'a'), tool(t, 'b'), tool(t, 'self')]));
  });

  test('Codex status follows later reports and stays correct for compacted sequence order', () {
    final t = Timeline();
    addTearDown(t.dispose);
    update(t, {
      'sessionUpdate': 'tool_call',
      'toolCallId': 'spawn',
      'title': 'spawnAgent',
      'status': 'completed',
      'rawInput': {
        'prompt': 'Audit',
        'receiverThreadIds': ['child'],
      },
    }, seq: 10);
    final agent = tool(t, 'spawn');
    expect(t.statusOfSubagent(agent), SubagentStatus.unknown);
    update(t, {
      'sessionUpdate': 'tool_call',
      'toolCallId': 'wait',
      'title': 'wait',
      'status': 'completed',
      'rawInput': {
        'agentsStates': {
          'child': {'status': 'completed', 'message': 'All clear'},
        },
      },
    }, seq: 30);
    expect(t.statusOfSubagent(agent), SubagentStatus.completed);
    expect(t.resultOfSubagent(agent), 'All clear');
    update(t, {
      'sessionUpdate': 'tool_call_update',
      'toolCallId': 'spawn',
      'rawInput': {
        'prompt': 'Audit',
        'receiverThreadIds': ['child'],
        'agentsStates': {
          'child': {'status': 'running'},
        },
      },
    }, seq: 20);
    expect(t.statusOfSubagent(agent), SubagentStatus.completed);
    expect(t.isSubagent(tool(t, 'wait')), isFalse);
    update(t, {'sessionUpdate': 'tool_call_update', 'toolCallId': 'spawn', 'title': 'spawnAgent'}, seq: 40);
    expect(t.statusOfSubagent(agent), SubagentStatus.completed);
    // A compacted call's overall seq may be newer than its agentsStates snapshot.
    update(t, {
      'sessionUpdate': 'tool_call',
      'toolCallId': 'old-spawn',
      'title': 'spawnAgent',
      'status': 'completed',
      'rawInput': {
        'receiverThreadIds': ['child'],
        'agentsStates': {
          'child': {'status': 'running'},
        },
      },
      '_meta': {
        'codeaw': {'agentStatesSeq': 20},
      },
    }, seq: 50);
    expect(t.statusOfSubagent(agent), SubagentStatus.completed);
    update(t, {'sessionUpdate': 'tool_call', 'toolCallId': 'multi', 'title': 'spawnAgent', 'status': 'completed', 'rawInput': {'receiverThreadIds': ['child', 'unknown-child']}}, seq: 51);
    expect(t.statusOfSubagent(tool(t, 'multi')), SubagentStatus.unknown);
  });

  testWidgets('expands child activity, updates folded progress and retains completion', (tester) async {
    final c = controller();
    addTearDown(c.dispose);
    demo(c.timeline);
    await tester.pumpWidget(conversation(c));
    expect(find.byType(SubagentCard), findsOneWidget);
    expect(find.text('執行中'), findsOneWidget);
    expect(find.text('工具 1/2'), findsOneWidget);
    expect(find.byType(ToolCallCard), findsNothing);
    await tester.tap(find.text('檢查聊天介面'));
    await tester.pump();
    expect(find.text('任務'), findsOneWidget);
    expect(find.text('活動紀錄 · 3'), findsOneWidget);
    expect(find.byType(ToolCallCard), findsNWidgets(2));
    await tester.tap(find.text('檢查聊天介面'));
    await tester.pump();
    update(c.timeline, {'sessionUpdate': 'tool_call_update', 'toolCallId': 'test', 'status': 'completed'});
    update(c.timeline, {'sessionUpdate': 'tool_call_update', 'toolCallId': 'agent', 'status': 'completed', 'rawOutput': '介面檢查完成'});
    await tester.pump();
    expect(find.text('工具 2/2'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
    await tester.tap(find.text('檢查聊天介面'));
    await tester.pump();
    expect(find.text('介面檢查完成'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final brightness in Brightness.values) {
    testWidgets('fits a narrow phone with large text in ${brightness.name} mode', (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = controller();
      addTearDown(c.dispose);
      demo(c.timeline);
      await tester.pumpWidget(conversation(c, brightness: brightness, textScale: 1.6));
      await tester.tap(find.text('檢查聊天介面'));
      await tester.pump();
      expect(find.text('活動紀錄 · 3'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('renders subagent phone preview', (tester) async {
    tester.view.physicalSize = const Size(430, 940);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final sdkFonts = '${Platform.environment['FLUTTER_ROOT'] ?? 'D:/flutter'}/bin/cache/artifacts/material_fonts';
    for (final entry in {
      'Roboto': '$sdkFonts/roboto-regular.ttf',
      'MaterialIcons': '$sdkFonts/materialicons-regular.otf',
      'NotoSansTC': 'C:/Windows/Fonts/NotoSansTC-VF.ttf',
    }.entries) {
      if (File(entry.value).existsSync()) {
        await (FontLoader(entry.key)..addFont(Future.value(ByteData.sublistView(File(entry.value).readAsBytesSync())))).load();
      }
    }
    final c = controller();
    addTearDown(c.dispose);
    demo(c.timeline);
    update(c.timeline, {
      ...delegation('history', status: 'completed'),
      'rawInput': {'description': '確認重連與歷史重播', 'subagent_type': 'Review', 'model': 'sonnet', 'prompt': '檢查重新連線後的訊息分組與狀態。'},
      'rawOutput': '重新連線後，子代理的活動與完成狀態都能保留。',
    });
    await tester.pumpWidget(conversation(c));
    await tester.tap(find.text('檢查聊天介面'));
    await tester.pump(const Duration(milliseconds: 200));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('screenshots/subagent_phone.png'));
    await tester.pumpWidget(const SizedBox());
  }, skip: Platform.environment['CODEAW_SCREENSHOTS'] != '1');
}
