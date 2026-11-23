/// Renders the main screens with realistic data into PNGs for eyeballing layout. Opt-in:
///   PowerShell: $env:CODEAW_SCREENSHOTS=1; flutter test --update-goldens test/screenshot_test.dart
/// Output: test/screenshots/*.png. Uses the Flutter SDK's Roboto and Windows' Noto Sans TC.
@Tags(['screenshots'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' show instantiateImageCodec;

import 'package:codeaw/acp/jsonrpc.dart';
import 'package:codeaw/app_state.dart';
import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/models.dart';
import 'package:codeaw/data/session_controller.dart';
import 'package:codeaw/data/sessions_model.dart';
import 'package:codeaw/data/timeline.dart';
import 'package:codeaw/ui/chat/chat_page.dart';
import 'package:codeaw/ui/chat/items.dart';
import 'package:codeaw/ui/chat/working_indicator.dart';
import 'package:codeaw/ui/common/app_theme.dart';
import 'package:codeaw/ui/common/diff_view.dart';
import 'package:codeaw/ui/common/markdown.dart';
import 'package:codeaw/ui/pair/pair_page.dart';
import 'package:codeaw/ui/sessions/sessions_page.dart';
import 'package:codeaw/ui/settings/settings_page.dart';
import 'package:codeaw/util/diff.dart';
import 'package:flutter/foundation.dart';
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

/// The app's own theme, with the fonts loaded below (the test binding has no platform fonts).
ThemeData _theme(Brightness b) => codeawTheme(b, fontFamily: 'Roboto', fontFamilyFallback: const ['NotoSansTC']);

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

Future<void> _shoot(WidgetTester tester, Widget app, String name, {bool decodeImages = false, Size size = const Size(1080, 2340), double ratio = 2.625}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = ratio;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(app);
  if (decodeImages) {
    final providers = tester.widgetList<Image>(find.byType(Image)).map((w) => w.image).toList();
    await tester.runAsync(() async {
      for (final provider in providers) {
        await precacheImage(provider, tester.element(find.byType(MaterialApp)));
      }
    });
  }
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
  await _capture(tester, name);
}

/// Paints real elevation shadows rather than flutter_test's outline stand-in.
Future<void> _capture(WidgetTester tester, String name) async {
  void repaint(RenderObject object) {
    object.markNeedsPaint();
    object.visitChildren(repaint);
  }

  debugDisableShadows = false;
  try {
    tester.binding.renderViews.forEach(repaint);
    await tester.pump();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('screenshots/$name.png'));
  } finally {
    debugDisableShadows = true;
  }
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
    await _shoot(tester, h.wrap(const SessionsPage(), brightness: Brightness.dark), 'sessions_dark');
    await tester.tap(find.text('新對話'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await _capture(tester, 'new_session_dark');
  });

  testWidgets('tablet sidebar', (tester) async {
    final h = _Harness();
    final now = DateTime.now();
    h.state.sessions!.sessions = [
      SessionSummary(id: 'claude:1', agentId: 'claude', cwd: r'D:\proj\codeaw', title: '透過 Tailscale 遠端使用 Claude Code', updatedAt: now, state: 'running', known: true),
      SessionSummary(id: 'codex:2', agentId: 'codex', cwd: r'D:\proj\web-app', title: '新增 nightly 建置流程', updatedAt: now.subtract(const Duration(minutes: 3)), state: 'requires_action', pending: 1, known: true),
      SessionSummary(id: 'claude:3', agentId: 'claude', cwd: r'D:\proj\cast-tool', title: '投影功能可行性評估', updatedAt: now.subtract(const Duration(hours: 2))),
      SessionSummary(id: 'kimi:4', agentId: 'kimi', cwd: r'D:\proj\card-game', title: null, updatedAt: now.subtract(const Duration(days: 2)), known: true),
    ];
    Widget page(Brightness brightness) => h.wrap(
      Scaffold(
        body: Row(children: [
          const SizedBox(width: 320, child: SessionsPage(sidebar: true, selectedSessionId: 'claude:3')),
          const VerticalDivider(width: 1),
          Expanded(child: Scaffold(appBar: AppBar(title: const Text('工作區')))),
        ]),
      ),
      brightness: brightness,
    );
    await _shoot(tester, page(Brightness.dark), 'sidebar_dark', size: const Size(2048, 1536), ratio: 2);
  });

  testWidgets('settings', (tester) async {
    final h = _Harness();
    await _shoot(tester, h.wrap(const SettingsPage(), brightness: Brightness.dark), 'settings_dark');
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
    // Scrolled back to the oldest message, which starts below the plan card rather than behind it.
    for (var i = 0; i < 4; i++) {
      await tester.dragFrom(const Offset(200, 500), const Offset(0, 600));
      await tester.pumpAndSettle();
    }
    final top = find.byType(TimelineItemView).evaluate().map((e) => tester.getRect(find.byWidget(e.widget)).top).reduce((a, b) => a < b ? a : b);
    expect(top, greaterThan(tester.getRect(find.text('計畫 1/3')).bottom));
    await _capture(tester, 'chat_dark_top');
    await tester.pumpWidget(const SizedBox());
    h.state.hub!.dispose();
    h.state.sessions!.dispose();
    h.client.dispose();
  });

  testWidgets('agent cards: shown files, a notice and quick replies', (tester) async {
    final h = _Harness();
    // The test binding blocks HTTP, so the bridge's preview is put into the image cache up front.
    final picture = File('test/fixtures/markdown_phone.png').readAsBytesSync();
    final preview = NetworkImage(h.client.httpUri('/api/fs/raw', {'path': r'D:\proj\shop\out\checkout.png'}).toString(), headers: h.client.authHeaders);
    await tester.runAsync(() async {
      final frame = await (await instantiateImageCodec(picture)).getNextFrame();
      imageCache.putIfAbsent(preview, () => OneFrameImageStreamCompleter(SynchronousFuture(ImageInfo(image: frame.image))));
    });
    addTearDown(imageCache.clear);
    const id = 'claude:cards';
    final c = h.state.hub!.adopt(id, r'D:\proj\shop', {
      'configOptions': [
        {'id': 'model', 'name': 'Model', 'category': 'model', 'type': 'select', 'currentValue': 'opus', 'options': [{'value': 'opus', 'name': 'Opus'}]},
      ],
      '_meta': {'codeaw': {'lastSeq': 0}},
    });
    void update(Map<String, dynamic> u) => c.onMessage(SessionMessage('session/update', {'sessionId': id, 'update': u}));
    void event(Map<String, dynamic> e) => c.onMessage(SessionMessage('_codeaw/event', {'sessionId': id, 'event': e}));
    void say(String mid, String text) => update({
      'sessionUpdate': 'agent_message_chunk',
      'content': {'type': 'text', 'text': text},
      '_meta': {'codeaw': {'mid': mid}},
    });
    final started = DateTime.now().subtract(const Duration(minutes: 4)).millisecondsSinceEpoch;
    update({
      'sessionUpdate': 'user_message_chunk',
      'content': {'type': 'text', 'text': '跑一次結帳頁的效能測試，結果給我看'},
      '_meta': {'codeaw': {'mid': 'u-p1', 'promptId': 'p1'}},
    });
    event({'type': 'state', 'state': 'running', 'queued': 0, 'turnStartedAt': started, 'turnPromptId': 'p1'});
    say('a1', '測試跑完了，結帳頁的 P95 從 **820 ms** 降到 **310 ms**。');
    event({'type': 'card', 'cardId': 'k_1', 'card': {
      'kind': 'files',
      'title': '結帳頁效能測試',
      'files': [
        {'path': r'D:\proj\shop\out\checkout.png', 'name': 'checkout.png', 'size': 172339, 'mimeType': 'image/png', 'caption': '優化後的結帳頁'},
        {'path': r'D:\proj\shop\out\latency-report.pdf', 'name': 'latency-report.pdf', 'size': 2411724, 'mimeType': 'application/pdf', 'caption': '完整報告，含各端點的延遲分佈'},
        {'path': r'D:\proj\shop\out\k6-summary.json', 'name': 'k6-summary.json', 'size': 8312},
      ],
    }});
    event({'type': 'card', 'cardId': 'k_2', 'card': {'kind': 'notice', 'title': '效能測試完成', 'message': 'P95 降到 310 ms，報告已放進聊天。'}});
    say('a2', '要把這次的改動提交嗎？');
    event({'type': 'card', 'cardId': 'k_3', 'card': {'kind': 'replies', 'replies': ['好，提交並推上去', '先跑完整測試', '把報告寄給團隊前讓我再看一次數字']}});
    event({
      'type': 'state', 'state': 'idle', 'queued': 0, 'stopReason': 'end_turn',
      'completedTurn': {'promptId': 'p1', 'startedAt': started, 'endedAt': started + 187000},
    });
    c.timeline.title = '結帳頁效能優化';
    c.timeline.flush();
    await _shoot(tester, h.wrap(ChatPage(sessionId: id, cwd: c.cwd)), 'agent_cards');
    await _shoot(tester, h.wrap(ChatPage(sessionId: id, cwd: c.cwd), brightness: Brightness.dark), 'agent_cards_dark');
    await tester.pumpWidget(const SizedBox());
    h.state.hub!.dispose();
    h.state.sessions!.dispose();
    h.client.dispose();
  });

  testWidgets('working status and elapsed time', (tester) async {
    final h = _Harness();
    final start = DateTime.utc(2026, 10, 2, 12);
    final timelines = List.generate(4, (_) => Timeline()..setTurnState('running', startedAt: start.millisecondsSinceEpoch));
    timelines[1].apply('session/update', {
      'update': {'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': '回覆'}},
      '_meta': {'codeaw': {'t': start.add(const Duration(seconds: 1)).millisecondsSinceEpoch}},
    });
    timelines[2].apply('session/update', {
      'update': {'sessionUpdate': 'tool_call', 'toolCallId': 'test', 'kind': 'execute', 'status': 'in_progress', 'title': 'flutter test test/working_indicator_test.dart'},
      '_meta': {'codeaw': {'t': start.add(const Duration(seconds: 1)).millisecondsSinceEpoch}},
    });
    timelines[2].queued = 2;
    timelines[3].setTurnState('requires_action', startedAt: start.millisecondsSinceEpoch);
    Widget page(Brightness brightness) => h.wrap(
      Scaffold(
        appBar: AppBar(title: const Text('處理進度')),
        body: Column(children: [for (final t in timelines) WorkingIndicator(timeline: t, now: () => start.add(const Duration(minutes: 1, seconds: 23)))]),
      ),
      brightness: brightness,
    );
    await _shoot(tester, page(Brightness.light), 'working');
    expect(find.text('回覆中…'), findsOneWidget);
    expect(find.text('執行指令中…'), findsOneWidget);
    await _shoot(tester, page(Brightness.dark), 'working_dark');
    await tester.pumpWidget(const SizedBox());
    for (final t in timelines) { t.dispose(); }
    h.state.hub!.dispose();
    h.state.sessions!.dispose();
    h.client.dispose();
  });

  testWidgets('completed turn metrics and actions', (tester) async {
    final h = _Harness();
    final c = h.state.hub!.adopt('codex:turn-summary', r'D:\proj\codeaw', {});
    final start = DateTime.utc(2026, 10, 3, 12);
    void event(Map<String, dynamic> e, int seconds) => c.timeline.apply('_codeaw/event', {
      'event': e,
      '_meta': {'codeaw': {'t': start.add(Duration(seconds: seconds)).millisecondsSinceEpoch}},
    });
    void message(String mid, String text, {bool user = false, String? promptId}) => c.timeline.apply('session/update', {
      'update': {
        'sessionUpdate': user ? 'user_message_chunk' : 'agent_message_chunk',
        'content': {'type': 'text', 'text': text},
        '_meta': {'codeaw': {'mid': mid, 'promptId': ?promptId}},
      },
    });
    for (var i = 0; i < 2; i++) {
      final promptId = 'p$i';
      final seconds = i * 100;
      message('u-$promptId', i == 0 ? '思考中右邊放 TPS，每回合結束也顯示耗時和複製按鈕。' : '重新開啟對話後還會保留嗎？', user: true, promptId: promptId);
      event({'type': 'state', 'state': 'running', 'turnStartedAt': start.add(Duration(seconds: seconds)).millisecondsSinceEpoch, 'turnPromptId': promptId}, seconds);
      message('m$i', i == 0 ? '已加入回合統計與操作列。\n\n- 狀態右側顯示估算 **TPS**\n- 回合底部保留 **耗時**\n- 可複製完整回覆、重新使用提示' : '會，回合統計會隨歷史一起載入，複製也包含該回合的完整回覆。');
      event({'type': 'state', 'state': 'idle', 'stopReason': 'end_turn'}, seconds + (i == 0 ? 83 : 8));
    }
    c.timeline.title = '回合統計與操作';
    c.timeline.flush();
    await _shoot(tester, h.wrap(ChatPage(sessionId: c.sessionId, cwd: c.cwd)), 'turn_summary');
    expect(find.byTooltip('複製回覆'), findsNWidgets(2));
    await _shoot(tester, h.wrap(ChatPage(sessionId: c.sessionId, cwd: c.cwd), brightness: Brightness.dark), 'turn_summary_dark');
    await tester.pumpWidget(const SizedBox());
    h.state.hub!.dispose();
    h.state.sessions!.dispose();
    h.client.dispose();
  });

  testWidgets('pair page', (tester) async {
    final h = _Harness()..state.host = null;
    await _shoot(tester, h.wrap(const PairPage()), 'pair');
  });

  testWidgets('markdown screenshot details collapsed and expanded', (tester) async {
    final h = _Harness();
    final image = base64Encode(File('test/fixtures/markdown_phone.png').readAsBytesSync());
    Widget page({required bool open}) => h.wrap(
      Scaffold(
        appBar: AppBar(title: const Text('Add iOS web build hosting')),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: SelectionArea(child: Markdown('''
- iOS：產出 `codeaw-ios-unsigned.ipa`，待 macOS CI 實際驗證。
- Web：手機、電腦皆可用，由 bridge host，並隨發行包附上 `web/`。

Web build 與測試通過。遠端使用可執行 `tailscale serve -bg 7860`，再開啟 HTTPS 網址。

<details${open ? ' open' : ''}>
<summary>手機尺寸實測畫面</summary>

![手機畫面](data:image/png;base64,$image)

點擊圖片可放大檢視。
</details>
''')),
        ),
      ),
      brightness: Brightness.dark,
    );
    await _shoot(tester, page(open: false), 'markdown_collapsed');
    // A fresh tree exercises the HTML open attribute rather than carrying state.
    await tester.pumpWidget(const SizedBox());
    await _shoot(tester, page(open: true), 'markdown_expanded', decodeImages: true);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    h.state.hub!.dispose();
    h.state.sessions!.dispose();
    h.client.dispose();
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
