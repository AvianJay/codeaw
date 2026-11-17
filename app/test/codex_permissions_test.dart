import 'package:codeaw/acp/jsonrpc.dart';
import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/session_controller.dart';
import 'package:codeaw/data/timeline.dart';
import 'package:codeaw/ui/chat/codex_permissions.dart';
import 'package:codeaw/ui/chat/composer.dart';
import 'package:codeaw/ui/chat/items.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const denial = 'CreateProcess rejected: blocked by policy';

class _Client extends BridgeClient {
  _Client({bool desktop = false})
    : super(
        HostConfig(
          name: 'fixture',
          urls: ['ws://localhost/acp'],
          token: 'fixture',
          deviceId: 'fixture',
          deviceName: 'fixture',
        ),
      ) {
    config = [
      {
        'id': 'mode',
        'category': 'mode',
        'name': 'Mode',
        'type': 'select',
        'currentValue': 'agent-full-access',
        'options': [
          {'value': 'workspace-write', 'name': 'Workspace access'},
          if (desktop)
            {'value': 'codeaw-full-access-on-request', 'name': '完整存取（手動核准）'},
          {'value': 'agent-full-access', 'name': 'Full access'},
        ],
      },
    ];
  }
  late List<Map<String, dynamic>> config;
  final requests = <Map<String, dynamic>>[];
  bool reject = false;
  @override
  Future<dynamic> request(String method, [Map<String, dynamic>? params]) async {
    requests.add({'method': method, ...?params});
    if (reject) throw RpcError(-32602, 'Settings rejected');
    expect(method, 'session/set_config_option');
    config = [
      for (final option in config)
        {...option, 'currentValue': params!['value']},
    ];
    return {'configOptions': config};
  }
}

({SessionController c, _Client client}) fixture({
  bool desktop = false,
  String agentId = 'codex',
}) {
  final client = _Client(desktop: desktop);
  final c = SessionController(client, '$agentId:test')..desktopSync = desktop;
  c.timeline.configOptions = client.config;
  addTearDown(() {
    c.dispose();
    client.dispose();
  });
  return (c: c, client: client);
}

ToolItem failedTool({
  String? title,
  String status = 'failed',
  Object? rawOutput = denial,
}) => ToolItem('tool:one', 'one')
  ..merge({
    'title': title ?? 'Run command',
    'kind': 'execute',
    'status': status,
    'rawOutput': rawOutput,
  });

void main() {
  test('recognizes host denial, not unrelated errors or command text', () {
    expect(toolReportsPolicyBlock(failedTool()), isTrue);
    expect(
      toolReportsPolicyBlock(failedTool(rawOutput: 'blocked by policy')),
      isTrue,
    );
    expect(
      toolReportsPolicyBlock(
        failedTool(
          rawOutput: {
            'error': {'message': denial},
          },
        ),
      ),
      isTrue,
    );
    expect(
      toolReportsPolicyBlock(
        failedTool(rawOutput: null)..terminalOutput = denial,
      ),
      isTrue,
    );
    expect(
      toolReportsPolicyBlock(
        failedTool(rawOutput: null)
          ..content = [
            {
              'type': 'content',
              'content': {'type': 'text', 'text': denial},
            },
          ],
      ),
      isTrue,
    );
    for (final tool in [
      failedTool(status: 'completed'),
      failedTool(rawOutput: 'HTTP 403: blocked by policy'),
      failedTool(rawOutput: 'documentation mentions blocked by policy'),
      failedTool(rawOutput: 'Access is denied'),
      failedTool(
        title: 'mcp.github.read',
        rawOutput: {
          'error': {'message': denial},
        },
      ),
      failedTool(rawOutput: null)..rawInput = {'command': 'echo "$denial"'},
    ]) {
      expect(toolReportsPolicyBlock(tool), isFalse);
    }
  });

  for (final desktop in [false, true]) {
    testWidgets(
      'denial links to supported ${desktop ? 'desktop' : 'ACP'} approval mode without rerunning',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final h = fixture(desktop: desktop);
        final tool = failedTool();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView(children: [ToolCallCard(tool, controller: h.c)]),
            ),
          ),
        );
        final label = desktop ? '完整存取（手動核准）' : 'Workspace access';
        expect(find.text('切換為「$label」'), findsOneWidget);
        expect(find.textContaining('政策明確禁止'), findsOneWidget);
        expect(h.client.requests, isEmpty);
        await tester.tap(find.text('Run command'));
        await tester.pumpAndSettle();
        expect(find.text(denial), findsOneWidget);
        await tester.tap(find.text('切換為「$label」'));
        await tester.pumpAndSettle();
        expect(h.client.requests, [
          {
            'method': 'session/set_config_option',
            'sessionId': 'codex:test',
            'configId': 'mode',
            'value': desktop
                ? 'codeaw-full-access-on-request'
                : 'workspace-write',
          },
        ]);
        expect(find.text('切換為「$label」'), findsNothing);
        expect(tool.rawOutput, denial);
        expect(find.text(denial), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('a rejected settings change keeps the original mode and denial', (
    tester,
  ) async {
    final h = fixture();
    h.client.reject = true;
    final errors = <String>[];
    final sub = h.c.toasts.listen(errors.add);
    addTearDown(sub.cancel);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TimelineItemView(
            item: ErrorItem('error:one', denial),
            controller: h.c,
            isLast: false,
          ),
        ),
      ),
    );
    await tester.tap(find.text('切換為「Workspace access」'));
    await tester.pumpAndSettle();
    expect(errors, ['Settings rejected']);
    expect(h.c.configOptions.single.currentValue, 'agent-full-access');
    expect(find.text(denial), findsOneWidget);
    expect(find.text('切換為「Workspace access」'), findsOneWidget);
  });

  testWidgets('mode menu explains full access using only advertised options', (
    tester,
  ) async {
    final h = fixture();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ConfigBar(controller: h.c)),
      ),
    );
    await tester.tap(find.text('Full access'));
    await tester.pumpAndSettle();
    expect(
      find.text('「Full access」不會詢問。要親自處理核准請求，請選「Workspace access」。'),
      findsOneWidget,
    );
    expect(find.text('完整存取（手動核准）'), findsNothing);
    expect(h.client.requests, isEmpty);
    await tester.tap(find.text('Workspace access'));
    await tester.pumpAndSettle();
    expect(h.client.requests.single['value'], 'workspace-write');
  });

  testWidgets('other agents and missing modes offer no misleading override', (
    tester,
  ) async {
    final other = fixture(agentId: 'claude');
    final missing = fixture();
    missing.c.timeline.configOptions!.single['options'] = [
      {'value': 'agent-full-access', 'name': 'Full access'},
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [CodexPolicyHint(other.c), CodexPolicyHint(missing.c)],
          ),
        ),
      ),
    );
    expect(find.byType(TextButton), findsNothing);
  });
}
