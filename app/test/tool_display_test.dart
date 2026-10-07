import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/session_controller.dart';
import 'package:codeaw/data/timeline.dart';
import 'package:codeaw/data/tool_display.dart';
import 'package:codeaw/ui/chat/items.dart';
import 'package:codeaw/ui/chat/working_indicator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void update(Timeline timeline, Map<String, dynamic> data) {
  timeline.apply('session/update', {'update': data});
  timeline.flush();
}

SessionController controller() => SessionController(
  BridgeClient(HostConfig(name: 'test', urls: ['ws://localhost:1'], token: 'test', deviceId: 'test', deviceName: 'test')),
  'claude:test',
);

Widget conversation(SessionController c) => MaterialApp(
  home: Scaffold(
    body: ListenableBuilder(
      listenable: c.timeline,
      builder: (context, _) => ListView(
        children: [
          for (final item in c.timeline.rootItems) TimelineItemView(key: ValueKey(item.key), item: item, controller: c, isLast: false),
          WorkingIndicator(timeline: c.timeline),
        ],
      ),
    ),
  ),
);

void main() {
  test('reads MCP server and tool from Claude, Kimi, DeepSeek and Codex names', () {
    final claude = mcpToolOf(
      title: 'mcp__context7__query-docs',
      name: 'mcp__context7__query-docs',
      rawInput: {'libraryId': '/flutter/flutter', 'query': 'MenuAnchor'},
    );
    expect(claude?.server, 'context7');
    expect(claude?.tool, 'query-docs');
    expect(claude?.arguments, {'libraryId': '/flutter/flutter', 'query': 'MenuAnchor'});
    expect(claude?.label, 'context7 · query-docs');
    final codex = mcpToolOf(
      title: 'mcp.github.create_issue',
      rawInput: {'server': 'github', 'tool': 'create_issue', 'arguments': {'title': 'Crash'}},
    );
    expect(codex?.label, 'github · create_issue');
    expect(codex?.arguments, {'title': 'Crash'});
    expect(mcpToolOf(title: 'mcp__plugin_context7_context7__resolve-library-id')?.serverLabel, 'context7');
    expect(mcpToolOf(title: 'mcp__plugin_figma_dev-mode__get_code')?.serverLabel, 'figma_dev-mode');
    expect(mcpToolOf(title: 'mcp__claude_ai_Google_Drive__search')?.serverLabel, 'Google Drive');
    expect(
      mcpToolOf(title: 'Query docs', metadata: {'claudeCode': {'toolName': 'mcp__context7__query-docs'}})?.tool,
      'query-docs',
    );
    for (final title in ['Read lib/main.dart', 'mcp', 'mcp__server', 'mcp.server', 'npm test']) {
      expect(mcpToolOf(title: title), isNull, reason: title);
    }
    expect(toolTitle(title: 'mcp__context7__query-docs'), 'context7 · query-docs');
    expect(
      toolTitle(title: 'mcp.browser.navigate', rawInput: {'server': 'browser', 'tool': 'navigate', 'arguments': {'title': '  開啟\n  專案頁面  '}}),
      '開啟 專案頁面',
    );
    expect(toolTitle(title: 'computer_use', rawInput: {'title': '檢查畫面'}), '檢查畫面');
    for (final value in [null, '', '  ', 123, true, ['title'], {'title': 'nested'}]) {
      expect(toolTitle(title: 'mcp__browser__navigate', rawInput: {'title': value}), 'browser · navigate');
    }
    expect(toolTitle(title: ' ', name: 'ToolSearch'), 'ToolSearch');
    expect(toolTitle(), '工具');
  });

  test('summarizes scalar arguments on one line', () {
    expect(
      argumentSummary({
        'query': 'How do\n  menus   work?',
        'limit': 5,
        'strict': true,
        'tags': ['a', 'b'],
        'options': {'x': 1},
        'empty': '',
        'none': null,
      }),
      'query: How do menus work? · limit: 5 · strict: true · tags: [2 項] · options: {…}',
    );
    expect(argumentSummary({}), isNull);
    expect(argumentSummary({'text': 'x' * 500})!.length, lessThan(140));
  });

  testWidgets('tool cards name the MCP server and tool and show what was asked', (tester) async {
    final c = controller();
    addTearDown(c.dispose);
    update(c.timeline, {
      'sessionUpdate': 'tool_call',
      'toolCallId': 'docs',
      'title': 'mcp__context7__query-docs',
      'name': 'mcp__context7__query-docs',
      'kind': 'other',
      'status': 'completed',
      'rawInput': {'libraryId': '/flutter/flutter', 'query': 'MenuAnchor alignment'},
      'content': [
        {'type': 'content', 'content': {'type': 'text', 'text': 'MenuAnchor positions its menu below the anchor.'}},
      ],
    });
    update(c.timeline, {
      'sessionUpdate': 'tool_call',
      'toolCallId': 'issue',
      'title': 'mcp.github.create_issue',
      'kind': 'execute',
      'status': 'completed',
      'rawInput': {'server': 'github', 'tool': 'create_issue', 'arguments': {'title': 'Crash'}},
      'rawOutput': {
        'result': {
          'content': [
            {'type': 'text', 'text': 'Created issue #12'},
          ],
        },
        'error': null,
      },
    });
    await tester.pumpWidget(conversation(c));
    expect(find.text('context7'), findsOneWidget);
    expect(find.text('github'), findsOneWidget);
    expect(find.textContaining('query-docs'), findsOneWidget);
    expect(find.textContaining('mcp__'), findsNothing);
    expect(find.byIcon(Icons.extension_outlined), findsNWidgets(2));
    expect(find.text('libraryId: /flutter/flutter · query: MenuAnchor alignment'), findsOneWidget);
    expect(find.text('Crash'), findsOneWidget);
    expect(find.text('title: Crash'), findsNothing);
    expect(tester.getTopLeft(find.text('Crash')).dy, lessThan(tester.getTopLeft(find.textContaining('create_issue')).dy));
    // Codex reports the MCP result only as rawOutput.
    await tester.tap(find.textContaining('create_issue'));
    await tester.pump();
    expect(find.text('Crash'), findsOneWidget);
    expect(find.text('Created issue #12'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('progress and permission requests use the readable name', (tester) async {
    final c = controller();
    addTearDown(c.dispose);
    c.timeline.setTurnState('requires_action');
    c.timeline.apply('_codeaw/event', {
      'event': {
        'type': 'permission_request',
        'requestId': 'r1',
        'toolCall': {'toolCallId': 'docs', 'title': 'mcp__context7__query-docs', 'rawInput': {'query': 'MenuAnchor'}},
        'options': const [],
      },
    });
    c.timeline.flush();
    await tester.pumpWidget(conversation(c));
    expect(find.text('context7 · query-docs'), findsOneWidget);
    c.timeline.setTurnState('running');
    update(c.timeline, {
      'sessionUpdate': 'tool_call',
      'toolCallId': 'docs',
      'title': 'mcp__context7__query-docs',
      'kind': 'other',
      'status': 'in_progress',
    });
    await tester.pump();
    expect(find.text('使用 MCP 工具中…'), findsOneWidget);
    expect(find.text('context7 · query-docs'), findsNWidgets(2));
    update(c.timeline, {
      'sessionUpdate': 'tool_call_update',
      'toolCallId': 'docs',
      'rawInput': {'title': '查詢 Flutter 選單用法', 'query': 'MenuAnchor'},
    });
    await tester.pump();
    // The card and working indicator both pick up titles arriving with arguments.
    expect(find.text('查詢 Flutter 選單用法'), findsNWidgets(2));
    expect(find.text('query: MenuAnchor'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
