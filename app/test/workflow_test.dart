import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/session_controller.dart';
import 'package:codeaw/data/subagent.dart';
import 'package:codeaw/data/timeline.dart';
import 'package:codeaw/data/workflow.dart';
import 'package:codeaw/ui/chat/items.dart';
import 'package:codeaw/ui/chat/subagent_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const script = r'''
// Generated for the startup animation
export const meta = {
  name: 'startup-animation-design',
  description: "Design 3 concepts, then judge them",
  phases: [
    { title: 'Design', detail: '3 concept designers', model: 'opus' },
    /* judges */
    { title: `Judge`, detail: 'UX + engineering\u2019s view', },
  ],
}

const BRIEF = `${args.topic}`
await phase('Design')
''';

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

Map<String, dynamic> launch() => {
  'sessionUpdate': 'tool_call',
  'toolCallId': 'wf',
  'title': 'Workflow',
  'name': 'Workflow',
  'kind': 'other',
  'status': 'completed',
  'rawInput': {'script': script},
  'rawOutput': 'Workflow launched in background. Task ID: w1',
  '_meta': {
    'claudeCode': {
      'toolName': 'Workflow',
      'toolResponse': {
        'status': 'async_launched',
        'taskId': 'w1',
        'runId': 'wf_1',
        'workflowName': 'startup-animation-design',
        'summary': 'Design 3 concepts, then judge them',
        'scriptPath': r'C:\Users\me\.claude\projects\p\s\workflows\scripts\startup-animation-design-wf_1.js',
      },
    },
  },
};

Map<String, dynamic> run(String state, {String? result}) => {
  'sessionUpdate': 'tool_call_update',
  'toolCallId': 'wf',
  '_meta': {
    'codeawWorkflow': {'state': state, 'runId': 'wf_1', 'taskId': 'w1', 'name': 'startup-animation-design', 'result': ?result},
  },
};

Map<String, dynamic> agent(String id, String label, String phase, String state) => {
  'sessionUpdate': 'tool_call',
  'toolCallId': 'workflow:wf:$id',
  'title': label,
  'kind': 'think',
  'status': state == 'running' ? 'in_progress' : state == 'completed' ? 'completed' : 'failed',
  'rawInput': {'description': label, 'prompt': 'Work on $label'},
  '_meta': {
    'parentToolCallId': 'wf',
    'codeawWorkflowAgent': {'agentId': id, 'runId': 'wf_1', 'label': label, 'phase': phase, 'model': 'opus', 'state': state},
  },
};

ToolItem tool(Timeline t, String id) => t.items.whereType<ToolItem>().firstWhere((item) => item.toolCallId == id);

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
          for (final item in c.timeline.rootItems)
            TimelineItemView(key: ValueKey(item.key), item: item, controller: c, isLast: false),
        ],
      ),
    ),
  ),
);

void main() {
  test('reads the literal metadata of a workflow script', () {
    final meta = workflowScriptMeta(script)!;
    expect(meta['name'], 'startup-animation-design');
    expect(meta['description'], 'Design 3 concepts, then judge them');
    final phases = meta['phases'] as List;
    expect(phases.map((p) => (p as Map)['title']), ['Design', 'Judge']);
    expect((phases[1] as Map)['detail'], 'UX + engineering’s view');
    expect(workflowScriptMeta("export const meta = { name: `x\${y}` }"), isNull);
    expect(workflowScriptMeta('const meta = { name: "a", count: 2, ok: true, none: null }'), {'name': 'a', 'count': 2, 'ok': true, 'none': null});
    expect(workflowScriptMeta('agent("no meta")'), isNull);
  });

  test('describes a launch from the script, its response and a deferred header', () {
    final live = WorkflowInfo.fromTool(name: 'Workflow', title: 'Workflow', input: launch()['rawInput'], metadata: launch()['_meta'])!;
    expect(live.name, 'startup-animation-design');
    expect(live.phases.map((p) => '${p.title}:${p.detail}'), ['Design:3 concept designers', 'Judge:UX + engineering’s view']);
    expect(live.runId, 'wf_1');

    final deferred = WorkflowInfo.fromTool(name: 'Workflow', title: 'Workflow', metadata: {
      'claudeCode': {'toolName': 'Workflow'},
      'codeawWorkflow': {'state': 'running', 'name': 'review', 'summary': 'Review the diff'},
    })!;
    expect((deferred.name, deferred.description), ('review', 'Review the diff'));
    expect(deferred.phases, isEmpty);

    final byPath = WorkflowInfo.fromTool(name: 'Workflow', input: {'scriptPath': '/tmp/scripts/spec-wf_9a-1.js'})!;
    expect(byPath.name, 'spec');
    expect(WorkflowInfo.fromTool(name: 'Bash', input: {'script': script}), isNull);
    expect(WorkflowInfo.fromTool(name: 'Workflow', title: 'Run the deploy workflow'), isNull);
  });

  test('parses task notifications without reading tags inside the result', () {
    final notice = TaskNotification.parse(
      '<task-notification>\n<task-id>w1</task-id>\n<tool-use-id>wf</tool-use-id>\n<output-file>C:\\t\\w1.output</output-file>\n'
      '<status>completed</status>\n<summary>Dynamic workflow &quot;A -&gt; B&quot; completed</summary>\n'
      '<result>{"status":"<status>failed</status>"}</result>\n</task-notification>',
    )!;
    expect(notice.toolUseId, 'wf');
    expect(notice.subagentStatus, SubagentStatus.completed);
    expect(notice.summary, 'Dynamic workflow "A -> B" completed');
    expect(notice.result, '{"status":"<status>failed</status>"}');
    expect(TaskNotification.parse('please read <task-notification>'), isNull);
  });

  test('a followed run keeps running after its turn and nests its agents', () {
    final t = Timeline();
    t.setTurnState('running');
    update(t, launch(), seq: 1);
    t.setTurnState('idle');
    final wf = tool(t, 'wf');
    expect(t.isSubagent(wf), isTrue);
    // Without the bridge's reports, completion of a background launch is unknown.
    expect(subagentStatusLabel(t, wf), '未回報完成');

    update(t, run('running'), seq: 2);
    update(t, agent('a1', 'design:brand', 'Design', 'running'), seq: 3);
    update(t, agent('a2', 'design:content', 'Design', 'completed'), seq: 4);
    expect(t.rootItems.whereType<ToolItem>().map((i) => i.toolCallId), ['wf']);
    expect(t.childrenOf(wf).length, 2);
    expect(t.statusOfSubagent(wf), SubagentStatus.running);
    expect(subagentStatusLabel(t, wf), '背景執行中');
    final brand = tool(t, 'workflow:wf:a1');
    expect((brand.subagent!.name, brand.subagent!.role, brand.subagent!.model, brand.subagent!.task), ('design:brand', 'Design', 'opus', 'Work on design:brand'));
    expect(subagentStatusLabel(t, brand), '背景執行中');

    update(t, {...agent('a1', 'design:brand', 'Design', 'stopped'), 'sessionUpdate': 'tool_call_update'}, seq: 5);
    update(t, run('stopped'), seq: 6);
    expect(t.statusOfSubagent(brand), SubagentStatus.cancelled);
    expect(t.statusOfSubagent(wf), SubagentStatus.cancelled);
    expect(subagentStatusLabel(t, wf), '已停止');
  });

  test('a replayed task notification settles the launch and is not a prompt', () {
    final t = Timeline();
    update(t, launch(), seq: 1);
    update(t, {
      'sessionUpdate': 'user_message_chunk',
      'content': {'type': 'text', 'text': '<task-notification>\n<task-id>w1</task-id>\n<tool-use-id>wf</tool-use-id>\n<status>failed</status>\n<summary>Dynamic workflow failed</summary>\n</task-notification>'},
      '_meta': {
        'codeaw': {'mid': 'n1'},
      },
    }, seq: 2);
    expect(t.statusOfSubagent(tool(t, 'wf')), SubagentStatus.failed);
    t.setTurnState('running');
    expect(t.currentTurn!.prompt, isNull);
  });

  testWidgets('shows a workflow card with phase progress and a compact notification', (tester) async {
    tester.view.physicalSize = const Size(1080, 4000);
    addTearDown(tester.view.reset);
    final c = controller();
    final t = c.timeline;
    update(t, launch(), seq: 1);
    update(t, run('running'), seq: 2);
    update(t, agent('a1', 'design:brand', 'Design', 'completed'), seq: 3);
    update(t, agent('a2', 'design:content', 'Design', 'running'), seq: 4);
    update(t, {
      'sessionUpdate': 'user_message_chunk',
      'content': {'type': 'text', 'text': '<task-notification>\n<task-id>b1</task-id>\n<tool-use-id>bash</tool-use-id>\n<status>completed</status>\n<summary>Background command "flutter test" completed</summary>\n</task-notification>'},
      '_meta': {
        'codeaw': {'mid': 'n1'},
      },
    }, seq: 5);
    await tester.pumpWidget(conversation(c));
    expect(find.text('Workflow'), findsOneWidget);
    expect(find.text('startup-animation-design'), findsOneWidget);
    expect(find.text('Agent 1/2'), findsOneWidget);
    expect(find.text('Design 1/2'), findsOneWidget);
    expect(find.text('Judge'), findsOneWidget);
    expect(find.text('背景工作已完成：Background command "flutter test" completed'), findsOneWidget);
    expect(find.textContaining('<task-notification>'), findsNothing);

    await tester.tap(find.text('startup-animation-design'));
    await tester.pump();
    expect(find.text('Agent · 2'), findsOneWidget);
    expect(find.text('腳本 · 13 行'), findsOneWidget);
    expect(find.textContaining('Run wf_1'), findsOneWidget);

    // A lazy history defers a large agent result behind a download button.
    update(t, {
      ...agent('a1', 'design:brand', 'Design', 'completed'),
      'sessionUpdate': 'tool_call_update',
      '_meta': {
        ...agent('a1', 'design:brand', 'Design', 'completed')['_meta'] as Map<String, dynamic>,
        'codeaw': {
          'deferredTool': {'seq': 3, 'bytes': 9000},
        },
      },
    }, seq: 6);
    await tester.pump();
    await tester.tap(find.text('design:brand'));
    await tester.pump();
    expect(find.text('讀取完整輸出'), findsOneWidget);
    c.dispose();
  });
}
