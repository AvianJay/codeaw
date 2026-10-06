import 'dart:io';

import 'package:codeaw/app_state.dart';
import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/models.dart';
import 'package:codeaw/data/session_controller.dart';
import 'package:codeaw/data/subagent.dart';
import 'package:codeaw/data/timeline.dart';
import 'package:codeaw/ui/chat/items.dart';
import 'package:codeaw/ui/chat/chat_page.dart';
import 'package:codeaw/ui/chat/subagent_card.dart';
import 'package:codeaw/ui/chat/subagent_panel.dart';
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

Map<String, dynamic> delegation(
  String id, {
  String? parent,
  String status = 'in_progress',
}) => {
  'sessionUpdate': 'tool_call',
  'toolCallId': id,
  'kind': 'other',
  'status': status,
  'title': '檢查聊天介面',
  'rawInput': {
    'description': '檢查聊天介面',
    'prompt': '檢查手機版排版與工具狀態，整理需要調整的地方。',
    'subagent_type': 'Explore',
    'model': 'sonnet',
  },
  '_meta': {
    'claudeCode': {'toolName': 'Agent', 'parentToolUseId': ?parent},
  },
};

Map<String, dynamic> message(
  String text, {
  String? parent,
  String mid = 'same',
}) => {
  'sessionUpdate': 'agent_message_chunk',
  'content': {'type': 'text', 'text': text},
  '_meta': {
    'codeaw': {'mid': mid},
    if (parent != null) 'claudeCode': {'parentToolUseId': parent},
  },
};

ToolItem tool(Timeline t, String id) =>
    t.items.whereType<ToolItem>().firstWhere((item) => item.toolCallId == id);

// Start the drawer ticker, then advance it. pumpAndSettle cannot be used while
// the conversation contains live progress indicators.
Future<void> animateDrawer(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

SessionController controller() {
  final client = BridgeClient(
    HostConfig(
      name: 'test',
      urls: ['ws://localhost:1'],
      token: 'test',
      deviceId: 'test',
      deviceName: 'test',
    ),
  );
  return SessionController(client, 'claude:test');
}

Widget conversation(
  SessionController c, {
  Brightness brightness = Brightness.light,
  double textScale = 1,
}) => MaterialApp(
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
            for (final item in c.timeline.rootItems)
              TimelineItemView(
                key: ValueKey(item.key),
                item: item,
                controller: c,
                isLast: false,
              ),
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

class _PanelClient extends BridgeClient {
  _PanelClient(super.host) {
    status = ConnStatus.online;
    agents = [AgentInfo(id: 'claude', name: 'Claude Code', status: 'ready')];
  }

  @override
  Future<dynamic> request(
    String method, [
    Map<String, dynamic>? params,
  ]) async => {};
}

class _PanelHarness {
  bool _disposed = false;
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    state.dispose();
  }

  _PanelHarness({bool delegated = true}) {
    final host = HostConfig(
      name: 'test',
      urls: ['ws://localhost:1'],
      token: 'fixture',
      deviceId: 'fixture',
      deviceName: 'fixture',
    );
    final client = _PanelClient(host);
    state = AppState(HostStore(), openSession: (_) {})
      ..host = host
      ..client = client
      ..loaded = true;
    state.hub = SessionHub(client);
    c = state.hub!.adopt('claude:panel', '/projects/codeaw', {});
    if (!delegated) return;
    demo(c.timeline);
    update(c.timeline, {
      'sessionUpdate': 'tool_call_update',
      'toolCallId': 'agent',
      'status': 'completed',
    });
    update(c.timeline, {
      ...delegation('nested', parent: 'agent', status: 'completed'),
      'rawInput': {
        'description': '檢查歷史重播',
        'prompt': '確認子代理活動能正確重播。',
        'subagent_type': 'Review',
      },
      '_meta': {
        'claudeCode': {
          'parentToolUseId': 'agent',
          'toolName': 'Agent',
          'toolResponse': {'status': 'completed'},
        },
      },
    });
  }

  late final AppState state;
  late final SessionController c;

  Widget app({Brightness brightness = Brightness.light, double scale = 1}) =>
      AppScope(
        state: state,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorSchemeSeed: const Color(0xFF0F9D8A),
            brightness: brightness,
            fontFamily: 'Roboto',
            fontFamilyFallback: const ['NotoSansTC'],
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: const ChatPage(sessionId: 'claude:panel'),
        ),
      );
}

void main() {
  test(
    'identifies delegation from adapter fields without classifying ordinary tasks',
    () {
      expect(
        SubagentInfo.fromTool(
          name: 'Task',
          input: {'description': 'Audit'},
        )?.name,
        'Audit',
      );
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
          input: {
            'agentThreadId': 'id',
            'agentPath': '/root/test',
            'activityKind': 'started',
          },
        )?.name,
        'test',
      );
      expect(
        SubagentInfo.fromTool(
          title: 'Write subagent docs',
          input: {'command': 'cat Task.md'},
        ),
        isNull,
      );
      expect(
        SubagentInfo.fromTool(name: 'TaskOutput', input: {'task_id': 'x'}),
        isNull,
      );
      expect(
        reportedSubagentStatus(null, {
          'agent_id': 'codex-child',
          'status': 'completed',
        }),
        isNull,
      );
    },
  );

  test(
    'groups out-of-order children, preserves metadata on updates and notifies ancestors',
    () {
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
      update(t, {
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'read',
        'status': 'completed',
      });
      expect(t.childrenOf(parent), hasLength(2));
      expect(tool(t, 'read').parentToolCallId, 'agent');
      expect(notifications, 2);
      t.clear();
      expect(t.rootItems, isEmpty);
      expect(t.childrenOf(parent), isEmpty);
    },
  );

  test(
    'separates parallel child messages sharing IDs and excludes them from the parent answer',
    () {
      final t = Timeline()..setTurnState('running');
      addTearDown(t.dispose);
      update(t, delegation('a'));
      update(t, delegation('b'));
      update(t, message('Main'));
      update(t, message('A', parent: 'a'));
      update(t, message('B', parent: 'b'));
      update(t, message(' continues', parent: 'a'));
      expect(t.rootItems, hasLength(3));
      expect(
        (t.childrenOf(tool(t, 'a')).single as MessageItem).text,
        'A continues',
      );
      expect((t.childrenOf(tool(t, 'b')).single as MessageItem).text, 'B');
      expect(t.currentTurn!.responseText, 'Main');
    },
  );

  test('child user messages never become the next main-turn prompt', () {
    final t = Timeline();
    addTearDown(t.dispose);
    update(t, {
      ...message('Main prompt'),
      'sessionUpdate': 'user_message_chunk',
    });
    update(t, {
      ...message('Delegated prompt', parent: 'a'),
      'sessionUpdate': 'user_message_chunk',
    });
    t.setTurnState('running');
    expect(t.currentTurn!.prompt!.text, 'Main prompt');
  });

  test(
    'handles nested agents, missing parents and malformed cycles without hiding activity',
    () {
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
      expect(
        t.rootItems,
        containsAll([tool(t, 'a'), tool(t, 'b'), tool(t, 'self')]),
      );
    },
  );

  test('Claude launch completion cannot hide continuing child activity', () {
    final t = Timeline()..setTurnState('running');
    addTearDown(t.dispose);
    update(t, delegation('agent', status: 'completed'), seq: 2);
    update(t, {
      'sessionUpdate': 'tool_call',
      'toolCallId': 'read',
      'status': 'in_progress',
      '_meta': {
        'claudeCode': {'parentToolUseId': 'agent'},
      },
    }, seq: 3);
    expect(t.statusOfSubagent(tool(t, 'agent')), SubagentStatus.running);
    update(t, {
      'sessionUpdate': 'tool_call_update',
      'toolCallId': 'read',
      'status': 'completed',
    }, seq: 4);
    expect(t.statusOfSubagent(tool(t, 'agent')), SubagentStatus.running);
    update(t, {
      'sessionUpdate': 'tool_call_update',
      'toolCallId': 'agent',
      'status': 'completed',
    }, seq: 5);
    expect(t.statusOfSubagent(tool(t, 'agent')), SubagentStatus.completed);
    update(t, message('Resumed work', parent: 'agent'), seq: 6);
    expect(t.statusOfSubagent(tool(t, 'agent')), SubagentStatus.running);
  });

  test(
    'Claude async launch and authoritative completion survive stale child tools and resumes',
    () {
      final t = Timeline()..setTurnState('running');
      addTearDown(t.dispose);
      update(t, {
        ...delegation('agent', status: 'completed'),
        'rawInput': {'subagent_type': 'Explore', 'run_in_background': true},
      }, seq: 2);
      final agent = tool(t, 'agent');
      expect(agent.subagent!.launchOnly, isTrue);
      expect(t.statusOfSubagent(agent), SubagentStatus.running);
      update(t, {
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'agent',
        '_meta': {
          'claudeCode': {
            'toolResponse': {'isAsync': true, 'status': 'async_launched'},
          },
        },
      }, seq: 3);
      update(t, {
        'sessionUpdate': 'tool_call',
        'toolCallId': 'read',
        'status': 'in_progress',
        '_meta': {
          'claudeCode': {'parentToolUseId': 'agent'},
        },
      }, seq: 4);
      update(t, {
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'agent',
        '_meta': {
          'claudeCode': {
            'toolResponse': {'status': 'completed'},
          },
        },
      }, seq: 5);
      expect(t.statusOfSubagent(agent), SubagentStatus.completed);
      update(t, {
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'read',
        'status': 'in_progress',
      }, seq: 6);
      expect(t.statusOfSubagent(agent), SubagentStatus.running);
      update(t, {
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'agent',
        '_meta': {
          'claudeCode': {
            'toolResponse': {'status': 'failed'},
          },
        },
      }, seq: 7);
      expect(t.statusOfSubagent(agent), SubagentStatus.failed);
    },
  );

  test('folded cosmetic updates do not change completion order on replay', () {
    final t = Timeline()..setTurnState('running');
    addTearDown(t.dispose);
    update(t, {
      ...delegation('agent', status: 'completed'),
      '_meta': {
        'claudeCode': {'toolName': 'Agent'},
        'codeaw': {'toolStatusSeq': 2},
      },
    }, seq: 20);
    update(t, message('Still working', parent: 'agent'), seq: 8);
    expect(t.statusOfSubagent(tool(t, 'agent')), SubagentStatus.running);
    expect(
      t.latestActivityOf(tool(t, 'agent')),
      t.childrenOf(tool(t, 'agent')).single,
    );
  });

  test(
    'Codex status follows later reports and stays correct for compacted sequence order',
    () {
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
      update(t, {
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'spawn',
        'title': 'spawnAgent',
      }, seq: 40);
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
      update(t, {
        'sessionUpdate': 'tool_call',
        'toolCallId': 'multi',
        'title': 'spawnAgent',
        'status': 'completed',
        'rawInput': {
          'receiverThreadIds': ['child', 'unknown-child'],
        },
      }, seq: 51);
      expect(t.statusOfSubagent(tool(t, 'multi')), SubagentStatus.unknown);
    },
  );

  testWidgets(
    'expands child activity, updates folded progress and retains completion',
    (tester) async {
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
      update(c.timeline, {
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'test',
        'status': 'completed',
      });
      update(c.timeline, {
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'agent',
        'status': 'completed',
        'rawOutput': '介面檢查完成',
      });
      await tester.pump();
      expect(find.text('工具 2/2'), findsOneWidget);
      expect(find.text('已完成'), findsOneWidget);
      await tester.tap(find.text('檢查聊天介面'));
      await tester.pump();
      expect(find.text('介面檢查完成'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'fits a narrow phone with large text in ${brightness.name} mode',
      (tester) async {
        tester.view.physicalSize = const Size(320, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final c = controller();
        addTearDown(c.dispose);
        demo(c.timeline);
        await tester.pumpWidget(
          conversation(c, brightness: brightness, textScale: 1.6),
        );
        await tester.tap(find.text('檢查聊天介面'));
        await tester.pump();
        expect(find.text('活動紀錄 · 3'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'phone swipe opens all agents, shows nested entries and opens their activity',
    (tester) async {
      tester.view.physicalSize = const Size(430, 940);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final h = _PanelHarness();
      addTearDown(h.dispose);
      await tester.pumpWidget(h.app());
      await tester.pump();
      expect(find.byType(SubagentPanel), findsNothing);
      await tester.dragFrom(const Offset(370, 260), const Offset(-200, 0));
      await animateDrawer(tester);
      expect(find.text('所有子代理'), findsOneWidget);
      expect(find.text('共 2 個 · 1 個未結束'), findsOneWidget);
      final panel = find.byType(SubagentPanel);
      expect(tester.getRect(panel).right, lessThanOrEqualTo(430));
      expect(
        find.descendant(
          of: panel,
          matching: find.byIcon(Icons.subdirectory_arrow_right_rounded),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: panel, matching: find.text('flutter test')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('subagent-row:agent')));
      await tester.pump();
      expect(find.text('返回所有子代理'), findsOneWidget);
      expect(
        find.descendant(of: panel, matching: find.text('活動紀錄 · 4')),
        findsOneWidget,
      );
      await tester.tap(find.text('返回所有子代理'));
      await tester.pump();
      await tester.tap(find.text('未結束'));
      await tester.pump();
      expect(
        find.descendant(of: panel, matching: find.text('檢查歷史重播')),
        findsNothing,
      );
      await tester.tap(find.byTooltip('關閉子代理面板'));
      await animateDrawer(tester);
      expect(find.byType(SubagentPanel), findsNothing);
      await tester.tap(find.byTooltip('所有子代理'));
      await animateDrawer(tester);
      expect(find.byType(SubagentPanel), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      h.dispose();
    },
  );

  for (final size in [const Size(430, 940), const Size(1440, 940)]) {
    testWidgets(
      'subagent controls appear once work is delegated (${size.width.toInt()} wide)',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final h = _PanelHarness(delegated: false);
        addTearDown(h.dispose);
        update(h.c.timeline, message('一般回覆，沒有委派'));
        await tester.pumpWidget(h.app());
        await tester.pump();
        expect(find.byTooltip('所有子代理'), findsNothing);
        await tester.dragFrom(
          Offset(size.width - 60, 260),
          const Offset(-200, 0),
        );
        await animateDrawer(tester);
        expect(find.byType(SubagentPanel), findsNothing);
        demo(h.c.timeline);
        await tester.pump();
        expect(find.byTooltip('所有子代理'), findsOneWidget);
        if (size.width < 1000) {
          await tester.tap(find.byTooltip('所有子代理'));
          await animateDrawer(tester);
        }
        expect(find.byType(SubagentPanel), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        h.dispose();
      },
    );
  }

  testWidgets(
    'desktop sidebar toggles and updates when a child continues after launch completed',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 940);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final h = _PanelHarness();
      addTearDown(h.dispose);
      await tester.pumpWidget(h.app(brightness: Brightness.dark));
      await tester.pump();
      expect(find.byType(SubagentPanel), findsOneWidget);
      final panel = find.byType(SubagentPanel);
      expect(tester.getRect(panel).left, greaterThan(1000));
      expect(
        find.descendant(of: panel, matching: find.text('執行中')),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('關閉子代理面板'));
      await tester.pump();
      expect(find.byType(SubagentPanel), findsNothing);
      await tester.tap(find.byTooltip('所有子代理'));
      await tester.pump();
      expect(find.byType(SubagentPanel), findsOneWidget);
      update(h.c.timeline, {
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'test',
        'status': 'completed',
      });
      update(h.c.timeline, {
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'agent',
        'status': 'completed',
      });
      await tester.pump();
      expect(find.text('共 2 個 · 0 個未結束'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      h.dispose();
    },
  );

  testWidgets(
    'phone panel fits large text and keeps terminal and git in the menu',
    (tester) async {
      tester.view.physicalSize = const Size(320, 940);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final h = _PanelHarness();
      addTearDown(h.dispose);
      await tester.pumpWidget(h.app(scale: 1.6));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('所有子代理'));
      await animateDrawer(tester);
      expect(find.byType(SubagentPanel), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      h.dispose();
    },
  );

  testWidgets('renders subagent phone preview', (tester) async {
    tester.view.physicalSize = const Size(430, 940);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final sdkFonts =
        '${Platform.environment['FLUTTER_ROOT'] ?? 'D:/flutter'}/bin/cache/artifacts/material_fonts';
    for (final entry in {
      'Roboto': '$sdkFonts/roboto-regular.ttf',
      'MaterialIcons': '$sdkFonts/materialicons-regular.otf',
      'NotoSansTC': 'C:/Windows/Fonts/NotoSansTC-VF.ttf',
    }.entries) {
      if (File(entry.value).existsSync()) {
        await (FontLoader(entry.key)..addFont(
              Future.value(
                ByteData.sublistView(File(entry.value).readAsBytesSync()),
              ),
            ))
            .load();
      }
    }
    final c = controller();
    addTearDown(c.dispose);
    demo(c.timeline);
    update(c.timeline, {
      ...delegation('history', status: 'completed'),
      'rawInput': {
        'description': '確認重連與歷史重播',
        'subagent_type': 'Review',
        'model': 'sonnet',
        'prompt': '檢查重新連線後的訊息分組與狀態。',
      },
      'rawOutput': '重新連線後，子代理的活動與完成狀態都能保留。',
    });
    await tester.pumpWidget(conversation(c));
    await tester.tap(find.text('檢查聊天介面'));
    await tester.pump(const Duration(milliseconds: 200));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/subagent_phone.png'),
    );
    await tester.pumpWidget(const SizedBox());
  }, skip: Platform.environment['CODEAW_SCREENSHOTS'] != '1');

  testWidgets('previews phone drawer and desktop sidebar', (tester) async {
    final sdkFonts =
        '${Platform.environment['FLUTTER_ROOT'] ?? 'D:/flutter'}/bin/cache/artifacts/material_fonts';
    for (final entry in {
      'Roboto': '$sdkFonts/roboto-regular.ttf',
      'MaterialIcons': '$sdkFonts/materialicons-regular.otf',
      'NotoSansTC': 'C:/Windows/Fonts/NotoSansTC-VF.ttf',
    }.entries) {
      if (File(entry.value).existsSync()) {
        await (FontLoader(entry.key)..addFont(
              Future.value(
                ByteData.sublistView(File(entry.value).readAsBytesSync()),
              ),
            ))
            .load();
      }
    }
    addTearDown(tester.view.reset);
    for (final size in [const Size(430, 940), const Size(1440, 940)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      final h = _PanelHarness();
      await tester.pumpWidget(
        h.app(
          brightness: size.width < 1000 ? Brightness.light : Brightness.dark,
        ),
      );
      await tester.pump();
      if (size.width < 1000) {
        await tester.tap(find.byTooltip('所有子代理'));
        await animateDrawer(tester);
      }
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile(
          'screenshots/subagent_${size.width < 1000 ? 'drawer' : 'sidebar'}.png',
        ),
      );
      await tester.pumpWidget(const SizedBox());
      h.state.dispose();
    }
  }, skip: Platform.environment['CODEAW_SCREENSHOTS'] != '1');
}
