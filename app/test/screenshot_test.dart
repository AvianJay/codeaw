/// Renders the main screens with realistic data into PNGs for eyeballing layout. Opt-in:
///   PowerShell: $env:CODEAW_SCREENSHOTS=1; flutter test --update-goldens test/screenshot_test.dart
/// Output: test/screenshots/*.png. Uses the Flutter SDK's Roboto and Windows' Noto Sans TC.
@Tags(['screenshots'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:codeaw/acp/jsonrpc.dart';
import 'package:codeaw/app_state.dart';
import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/models.dart';
import 'package:codeaw/data/session_controller.dart';
import 'package:codeaw/data/sessions_model.dart';
import 'package:codeaw/ui/chat/chat_page.dart';
import 'package:codeaw/ui/common/diff_view.dart';
import 'package:codeaw/ui/pair/pair_page.dart';
import 'package:codeaw/ui/sessions/sessions_page.dart';
import 'package:codeaw/util/diff.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _font(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    if (File(f).existsSync()) loader.addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
  }
  await loader.load();
}

final _sdkFonts = '${Platform.environment['FLUTTER_ROOT'] ?? 'C:/flutter'}/bin/cache/artifacts/material_fonts';

ThemeData _theme(Brightness b) {
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF0F9D8A), brightness: b);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    fontFamily: 'Roboto',
    fontFamilyFallback: const ['NotoSansTC'],
    appBarTheme: AppBarTheme(backgroundColor: scheme.surface),
  );
}

class _Harness {
  _Harness() {
    host = HostConfig(name: 'my-pc', urls: ['ws://100.64.0.10:7860/acp'], token: 't', deviceId: 'd_1', deviceName: 'Pixel');
    client = BridgeClient(host)
      ..status = ConnStatus.online
      ..bridgeHost = 'my-pc'
      ..agents = [
        AgentInfo(id: 'claude', name: 'Claude Code', status: 'ready', steering: true, image: true, version: '0.85.0'),
        AgentInfo(id: 'codex', name: 'Codex', status: 'ready', steering: true, image: true),
        AgentInfo(id: 'kimi', name: 'Kimi Code', status: 'stopped'),
      ];
    state = AppState(HostStore(), openSession: (_) {})
      ..host = host
      ..client = client
      ..loaded = true;
    state.hub = SessionHub(client);
    state.sessions = SessionsModel(client);
  }

  late final HostConfig host;
  late final BridgeClient client;
  late final AppState state;

  Widget wrap(Widget child, {Brightness brightness = Brightness.light}) => AppScope(
        state: state,
        child: MaterialApp(debugShowCheckedModeBanner: false, theme: _theme(brightness), home: child),
      );
}

Future<void> _shoot(WidgetTester tester, Widget app, String name) async {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(app);
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('screenshots/$name.png'));
}

final _enabled = Platform.environment['CODEAW_SCREENSHOTS'] == '1';

void main() {
  if (!_enabled) {
    test('screenshots (set CODEAW_SCREENSHOTS=1 to render)', () {}, skip: true);
    return;
  }
  setUpAll(() async {
    await _font('Roboto', ['$_sdkFonts/roboto-regular.ttf', '$_sdkFonts/roboto-medium.ttf', '$_sdkFonts/roboto-bold.ttf']);
    await _font('MaterialIcons', ['$_sdkFonts/materialicons-regular.otf']);
    await _font('NotoSansTC', ['C:/Windows/Fonts/NotoSansTC-VF.ttf']);
    await _font('monospace', ['C:/Windows/Fonts/CascadiaMono.ttf', 'C:/Windows/Fonts/consola.ttf']);
  });

  testWidgets('sessions list', (tester) async {
    final h = _Harness();
    final now = DateTime.now();
    h.state.sessions!.sessions = [
      SessionSummary(id: 'claude:1', agentId: 'claude', cwd: r'D:\proj\codeaw', title: '透過 Tailscale 遠端使用 Claude Code', updatedAt: now, state: 'requires_action', pending: 1, known: true),
      SessionSummary(id: 'codex:2', agentId: 'codex', cwd: r'D:\proj\web-app', title: '新增 nightly 建置流程', updatedAt: now.subtract(const Duration(minutes: 3)), state: 'running', queued: 1, known: true),
      SessionSummary(id: 'claude:3', agentId: 'claude', cwd: r'D:\proj\cast-tool', title: '投影功能可行性評估', updatedAt: now.subtract(const Duration(hours: 2))),
      SessionSummary(id: 'kimi:4', agentId: 'kimi', cwd: r'D:\proj\card-game', title: null, updatedAt: now.subtract(const Duration(days: 2)), known: true),
      SessionSummary(id: 'claude:5', agentId: 'claude', cwd: r'D:\proj\discord-bot', title: '工單 modal 的管理員設定', updatedAt: now.subtract(const Duration(days: 9))),
    ];
    await _shoot(tester, h.wrap(const SessionsPage()), 'sessions');
  });

  testWidgets('chat with tools, permission and plan', (tester) async {
    final h = _Harness();
    final fixture = jsonDecode(File('test/fixtures/replay.json').readAsStringSync()) as Map<String, dynamic>;
    final c = h.state.hub!.adopt('claude:abc', r'D:\proj\codeaw', {
      'configOptions': [
        {'id': 'mode', 'name': 'Mode', 'category': 'mode', 'type': 'select', 'currentValue': 'default', 'options': [{'value': 'default', 'name': 'Manual'}, {'value': 'acceptEdits', 'name': 'Accept Edits'}]},
        {'id': 'model', 'name': 'Model', 'category': 'model', 'type': 'select', 'currentValue': 'opus', 'options': [{'value': 'opus', 'name': 'Opus'}]},
        {'id': 'effort', 'name': 'Effort', 'category': 'thought_level', 'type': 'select', 'currentValue': 'xhigh', 'options': [{'value': 'xhigh', 'name': 'Xhigh'}]},
        {'id': 'fast', 'name': 'Fast mode', 'category': 'model_config', 'type': 'boolean', 'currentValue': false},
      ],
      '_meta': {'codeaw': {'lastSeq': 0}},
    });
    for (final m in (fixture['raw'] as List).cast<Map<String, dynamic>>()) {
      final params = Map<String, dynamic>.from(m['params'] as Map)..['sessionId'] = 'claude:abc';
      c.onMessage(SessionMessage(m['method'] as String, params));
    }
    void update(Map<String, dynamic> u) => c.onMessage(SessionMessage('session/update', {'sessionId': 'claude:abc', 'update': u}));
    update({
      'sessionUpdate': 'agent_message_chunk',
      'content': {'type': 'text', 'text': '我改了 `bridge/src/session/manager.ts`：\n\n- 斷線時保留 session\n- 權限請求**先回者生效**\n\n```ts\nconst seq = ++s.meta.lastSeq;\nstore.append(s.id, entry);\n```\n接著要跑測試。'},
      '_meta': {'codeaw': {'mid': 'final'}},
    });
    update({
      'sessionUpdate': 'tool_call',
      'toolCallId': 'edit2',
      'title': 'Edit bridge/src/session/manager.ts',
      'kind': 'edit',
      'status': 'completed',
      'content': [
        {'type': 'diff', 'path': r'D:\proj\codeaw\bridge\src\session\manager.ts', 'oldText': 'const a = 1;\nfunction x() {\n  return a;\n}\n', 'newText': 'const a = 2;\nfunction x() {\n  return a + 1;\n}\n'},
      ],
    });
    update({
      'sessionUpdate': 'plan',
      'entries': [
        {'content': '寫 bridge 的 session manager', 'status': 'completed', 'priority': 'high'},
        {'content': '跑測試並修正失敗', 'status': 'in_progress', 'priority': 'high'},
        {'content': '寫 README', 'status': 'pending', 'priority': 'medium'},
      ],
    });
    update({'sessionUpdate': 'usage_update', 'used': 53210, 'size': 200000, 'cost': {'amount': 0.42, 'currency': 'USD'}});
    c.onMessage(SessionMessage('_codeaw/event', {'sessionId': 'claude:abc', 'event': {'type': 'state', 'state': 'requires_action', 'queued': 0}}));
    c.timeline.title = 'codeaw bridge 實作';
    final token = CancelToken();
    c.onServerRequest('session/request_permission', {
      'sessionId': 'claude:abc',
      'toolCall': {'toolCallId': 'b1', 'title': 'npm test', 'kind': 'execute', 'rawInput': {'command': 'cd bridge && npm test'}},
      'options': [
        {'optionId': 'allow_always', 'name': 'Always Allow Bash(npm test:*)', 'kind': 'allow_always'},
        {'optionId': 'allow', 'name': 'Allow', 'kind': 'allow_once'},
        {'optionId': 'reject', 'name': 'Reject', 'kind': 'reject_once'},
      ],
      '_meta': {'codeaw': {'requestId': 'r_live'}},
    }, token);
    c.timeline.flush();
    await _shoot(tester, h.wrap(ChatPage(sessionId: c.sessionId, cwd: c.cwd)), 'chat');
    token.cancel();
    await _shoot(tester, h.wrap(ChatPage(sessionId: c.sessionId, cwd: c.cwd), brightness: Brightness.dark), 'chat_dark');
  });

  testWidgets('pair page', (tester) async {
    final h = _Harness()..state.host = null;
    await _shoot(tester, h.wrap(const PairPage()), 'pair');
  });

  testWidgets('diff view', (tester) async {
    final h = _Harness();
    const text = 'diff --git a/src/a.ts b/src/a.ts\n--- a/src/a.ts\n+++ b/src/a.ts\n@@ -10,6 +10,7 @@ export function main() {\n   const config = load();\n-  const port = 7860;\n+  const port = config.port ?? 7860;\n+  log.info(`listening on \${port}`);\n   start(port);\n }\n';
    await _shoot(
      tester,
      h.wrap(Scaffold(appBar: AppBar(title: const Text('a.ts')), body: Padding(padding: const EdgeInsets.all(8), child: DiffView(lines: parseUnifiedDiff(text).single.lines)))),
      'diff',
    );
  });
}
