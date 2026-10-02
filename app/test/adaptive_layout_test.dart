import 'dart:async';
import 'dart:io';

import 'package:codeaw/app_state.dart';
import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/models.dart';
import 'package:codeaw/main.dart';
import 'package:codeaw/ui/chat/chat_page.dart';
import 'package:codeaw/ui/chat/composer.dart';
import 'package:codeaw/ui/chat/items.dart';
import 'package:codeaw/ui/files/file_view_page.dart';
import 'package:codeaw/ui/files/git_page.dart';
import 'package:codeaw/ui/pair/pair_page.dart';
import 'package:codeaw/ui/sessions/sessions_page.dart';
import 'package:codeaw/ui/settings/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _cwd = '/projects/codeaw';
const _first = 'codex:first';
const _second = 'claude:second';

class _Client extends BridgeClient {
  _Client(super.host) {
    status = ConnStatus.online;
    bridgeHost = host.name;
    agents = [
      AgentInfo(id: 'codex', name: 'Codex', status: 'ready', steering: true),
      AgentInfo(id: 'claude', name: 'Claude Code', status: 'ready'),
    ];
  }

  final calls = <({String method, Map<String, dynamic>? params})>[];
  Completer<Map<String, dynamic>>? pendingRead;
  String? fileText;

  @override
  void start() {}

  @override
  Future<dynamic> request(String method, [Map<String, dynamic>? params]) async {
    calls.add((method: method, params: params));
    switch (method) {
      case 'session/list':
        return {
          'sessions': [
            {
              'sessionId': _first,
              'cwd': _cwd,
              'title': '桌面與平板版面調整',
              'updatedAt': '2026-10-02T08:00:00Z',
            },
            {
              'sessionId': _second,
              'cwd': '/projects/bridge',
              'title': 'Bridge 連線與重試',
            },
          ],
        };
      case 'session/new':
        return {'sessionId': 'codex:new'};
      case '_codeaw/workspaces/list':
        return {
          'roots': [
            {'name': 'codeaw', 'path': _cwd, 'source': 'config'},
          ],
        };
      case '_codeaw/fs/list':
        return {
          'path': _cwd,
          'entries': [
            {
              'name': 'main.dart',
              'path': '$_cwd/main.dart',
              'type': 'file',
              'size': 1200,
            },
            {
              'name': 'README.md',
              'path': '$_cwd/README.md',
              'type': 'file',
              'size': 400,
            },
          ],
        };
      case '_codeaw/fs/read':
        if (pendingRead != null) return pendingRead!.future;
        return {
          'text':
              fileText ??
              (params!['path'].toString().endsWith('.md')
                  ? '# codeaw\n\nA workspace for your coding agents.'
                  : 'void main() {\n  runApp(const CodeawApp());\n}\n'),
        };
      case '_codeaw/git/status':
        return {
          'root': _cwd,
          'branch': 'main',
          'files': [
            {'path': '$_cwd/main.dart', 'index': 'M', 'worktree': ' '},
            {'path': '$_cwd/README.md', 'index': ' ', 'worktree': 'M'},
          ],
        };
      case '_codeaw/git/diff':
        return {
          'diff':
              'diff --git a/main.dart b/main.dart\n--- a/main.dart\n+++ b/main.dart\n@@ -1 +1 @@\n-old layout\n+adaptive workspace\n',
        };
      default:
        return {};
    }
  }
}

HostConfig _host(String name) => HostConfig(
  name: name,
  urls: ['ws://$name.test/acp'],
  token: 'fixture',
  deviceId: 'fixture-$name',
  deviceName: 'test',
);

class _Harness {
  final state = AppState(
    HostStore(),
    openSession: (_) {},
    createClient: _Client.new,
  );
  late GoRouter router;
  _Client get client => state.client! as _Client;

  Future<void> show(
    WidgetTester tester,
    Size size, {
    String location = '/',
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await state.setHost(_host('dev-pc'));
    state.loaded = true;
    await state.sessions!.refresh();
    final c = state.hub!.adopt(_first, _cwd, {});
    c.timeline.apply('session/update', {
      'update': {
        'sessionUpdate': 'user_message_chunk',
        'content': {'type': 'text', 'text': '請重新設計桌面與平板版面，讓對話和工具更容易使用。'},
      },
    });
    c.timeline.apply('session/update', {
      'update': {
        'sessionUpdate': 'agent_message_chunk',
        'content': {
          'type': 'text',
          'text':
              '桌面改成常駐對話清單，平板使用導覽列。\n\n- 快速切換對話與電腦\n- 檔案與 Git 變更並排預覽\n- 聊天內容維持舒適的閱讀寬度\n\n```dart\nLayoutBuilder(\n  builder: (context, constraints) => workspace,\n);\n```',
        },
      },
    });
    c.timeline.flush();
    router = createAppRouter(state, initialLocation: location);
    addTearDown(() {
      router.dispose();
      state.dispose();
    });
    await tester.pumpWidget(
      AppScope(
        state: state,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          routerConfig: router,
          theme: ThemeData(
            useMaterial3: true,
            fontFamily: 'Roboto',
            fontFamilyFallback: const ['NotoSansTC'],
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF0F9D8A),
              brightness: brightness,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox());
}

Finder get _input => find.descendant(
  of: find.byType(Composer),
  matching: find.byType(TextField),
);

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  for (final width in [390.0, 720.0, 834.0, 1099.0, 1100.0, 1440.0]) {
    testWidgets('workspace navigation at $width pixels', (tester) async {
      final h = _Harness();
      await h.show(tester, Size(width, 900));
      expect(
        find.byType(NavigationRail),
        width >= 720 && width < 1100 ? findsOneWidget : findsNothing,
      );
      expect(
        find.byType(SessionsPage),
        width < 720 || width >= 1100 ? findsOneWidget : findsNothing,
      );
      expect(tester.takeException(), isNull);
      await h.close(tester);
    });
  }

  testWidgets('mouse wheel scrolls chat from both blank gutters', (
    tester,
  ) async {
    final h = _Harness();
    await h.show(tester, const Size(1920, 900), location: sessionRoute(_first));
    final c = h.state.hub!.peek(_first)!;
    c.timeline.apply('session/update', {
      'update': {
        'sessionUpdate': 'agent_message_chunk',
        'content': {
          'type': 'text',
          'text': List.generate(100, (i) => '訊息第 $i 行，保留中央閱讀寬度。').join('\n\n'),
        },
      },
    });
    c.timeline.flush();
    await tester.pumpAndSettle();
    final chat = find.byType(ChatPage);
    final scroll = tester.state<ScrollableState>(
      find.descendant(
        of: chat,
        matching: find.byWidgetPredicate(
          (w) => w is Scrollable && w.axisDirection == AxisDirection.up,
        ),
      ),
    );
    expect(scroll.position.maxScrollExtent, greaterThan(200));
    final bounds = tester.getRect(chat);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        kind: PointerDeviceKind.mouse,
        position: Offset(bounds.left + 24, bounds.center.dy),
        scrollDelta: const Offset(0, -120),
      ),
    );
    await tester.pumpAndSettle();
    expect(scroll.position.pixels, closeTo(120, .1));
    await tester.sendEventToBinding(
      PointerScrollEvent(
        kind: PointerDeviceKind.mouse,
        position: Offset(bounds.right - 24, bounds.center.dy),
        scrollDelta: const Offset(0, 80),
      ),
    );
    await tester.pumpAndSettle();
    expect(scroll.position.pixels, closeTo(40, .1));
    expect(
      tester.getSize(find.byType(TimelineItemView).first).width,
      lessThanOrEqualTo(960),
    );
    await tester.sendEventToBinding(
      const PointerScrollEvent(
        kind: PointerDeviceKind.mouse,
        position: Offset(100, 500),
        scrollDelta: Offset(0, 80),
      ),
    );
    await tester.pumpAndSettle();
    expect(scroll.position.pixels, closeTo(40, .1));
    expect(tester.takeException(), isNull);
    await h.close(tester);
  });

  testWidgets(
    'mouse wheel scrolls bounded forms and markdown from their gutters',
    (tester) async {
      final h = _Harness();
      await h.show(tester, const Size(1920, 460));
      h.client.fileText = List.generate(
        100,
        (i) => 'Markdown paragraph $i.',
      ).join('\n\n');
      for (final route in [
        '/pair',
        '/settings',
        '/file?path=$_cwd/README.md',
      ]) {
        h.router.go(route);
        await tester.pumpAndSettle();
        final page = route == '/pair'
            ? find.byType(PairPage)
            : route == '/settings'
            ? find.byType(SettingsPage)
            : find.byType(FileViewPage);
      final scroll = tester.state<ScrollableState>(
        find.descendant(
          of: page,
          matching: find.byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          ),
        ).first,
        );
        expect(scroll.position.maxScrollExtent, greaterThan(0), reason: route);
        final bounds = tester.getRect(page);
        await tester.sendEventToBinding(
          PointerScrollEvent(
            kind: PointerDeviceKind.mouse,
            position: Offset(bounds.left + 24, bounds.center.dy),
            scrollDelta: const Offset(0, 40),
          ),
        );
        await tester.pumpAndSettle();
        final afterLeft = scroll.position.pixels;
        expect(afterLeft, greaterThan(0), reason: '$route left gutter');
        await tester.sendEventToBinding(
          PointerScrollEvent(
            kind: PointerDeviceKind.mouse,
            position: Offset(bounds.right - 24, bounds.center.dy),
            scrollDelta: const Offset(0, -40),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          scroll.position.pixels,
          lessThan(afterLeft),
          reason: '$route right gutter',
        );
        expect(tester.takeException(), isNull);
      }
      await h.close(tester);
    },
  );

  testWidgets('chat survives resizing, switches sessions and keeps drafts', (
    tester,
  ) async {
    final h = _Harness();
    await h.show(tester, const Size(1440, 900), location: sessionRoute(_first));
    await tester.enterText(_input, 'unsent draft');
    for (final size in [
      const Size(834, 1112),
      const Size(390, 844),
      const Size(1440, 900),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(_input).controller!.text, 'unsent draft');
      expect(tester.takeException(), isNull);
    }
    await tester.tap(find.widgetWithText(ListTile, 'Bridge 連線與重試'));
    await tester.pumpAndSettle();
    expect(tester.widget<ChatPage>(find.byType(ChatPage)).sessionId, _second);
    expect(tester.widget<TextField>(_input).controller!.text, isEmpty);
    await tester.tap(find.widgetWithText(ListTile, '桌面與平板版面調整'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(_input).controller!.text, 'unsent draft');
    await tester.tap(_input);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    final prompt = h.client.calls
        .where((c) => c.method == 'session/prompt')
        .single;
    expect(prompt.params!['sessionId'], _first);
    expect(prompt.params!['prompt'], [
      {'type': 'text', 'text': 'unsent draft'},
    ]);
    expect(tester.widget<TextField>(_input).controller!.text, isEmpty);
    expect(tester.takeException(), isNull);
    await h.close(tester);
  });

  testWidgets('tablet keyboard keeps the composer above the keyboard', (
    tester,
  ) async {
    final h = _Harness();
    await h.show(tester, const Size(834, 1112), location: sessionRoute(_first));
    await tester.enterText(_input, '鍵盤開啟時仍可輸入訊息');
    tester.view.viewInsets = const FakeViewPadding(bottom: 420);
    await tester.pumpAndSettle();
    expect(
      tester.getBottomRight(find.byType(Composer)).dy,
      lessThanOrEqualTo(692),
    );
    expect(tester.widget<TextField>(_input).controller!.text, '鍵盤開啟時仍可輸入訊息');
    expect(tester.takeException(), isNull);
    await h.close(tester);
  });

  testWidgets('tablet opens session drawer and closes it on selection', (
    tester,
  ) async {
    final h = _Harness();
    await h.show(tester, const Size(834, 1112));
    await tester.tap(find.text('對話'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Bridge 連線與重試'));
    await tester.pumpAndSettle();
    expect(tester.widget<ChatPage>(find.byType(ChatPage)).sessionId, _second);
    expect(find.byType(Drawer), findsNothing);
    expect(tester.takeException(), isNull);
    await h.close(tester);
  });

  testWidgets('tablet session creation closes the session drawer', (
    tester,
  ) async {
    final h = _Harness();
    await h.show(tester, const Size(834, 1112));
    await tester.tap(find.text('對話'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '新對話'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '開始'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<ChatPage>(find.byType(ChatPage)).sessionId,
      'codex:new',
    );
    expect(find.byType(Drawer), findsNothing);
    expect(tester.takeException(), isNull);
    await h.close(tester);
  });

  testWidgets('short desktop dialog scrolls and creates a session', (
    tester,
  ) async {
    final h = _Harness();
    await h.show(tester, const Size(1280, 500));
    await tester.tap(find.widgetWithText(FilledButton, '建立新對話'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(
      tester
          .getSize(
            find
                .descendant(
                  of: find.byType(Dialog),
                  matching: find.byType(Material),
                )
                .first,
          )
          .width,
      lessThanOrEqualTo(560),
    );
    await tester.ensureVisible(find.widgetWithText(FilledButton, '開始'));
    await tester.tap(find.widgetWithText(FilledButton, '開始'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<ChatPage>(find.byType(ChatPage)).sessionId,
      'codex:new',
    );
    expect(tester.takeException(), isNull);
    await h.close(tester);
  });

  testWidgets(
    'desktop search and host switch clear the selected conversation',
    (tester) async {
      final h = _Harness();
      await h.show(
        tester,
        const Size(1440, 900),
        location: sessionRoute(_first),
      );
      await tester.enterText(
        find.descendant(
          of: find.byType(SessionsPage),
          matching: find.byType(TextField),
        ),
        'bridge',
      );
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, '桌面與平板版面調整'), findsNothing);
      expect(find.widgetWithText(ListTile, 'Bridge 連線與重試'), findsOneWidget);
      await h.state.setHost(_host('other-pc'));
      await h.state.setHost(h.state.hosts.first);
      await h.state.sessions!.refresh();
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'dev-pc'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      await tester.tap(find.text('other-pc'));
      await tester.pumpAndSettle();
      expect(h.router.routeInformationProvider.value.uri.path, '/');
      expect(find.byType(ChatPage), findsNothing);
      expect(h.state.host!.name, 'other-pc');
      expect(tester.takeException(), isNull);
      await h.close(tester);
    },
  );

  testWidgets(
    'file preview stays beside the directory and ignores a late response',
    (tester) async {
      final h = _Harness();
      await h.show(
        tester,
        const Size(1440, 900),
        location: '/files?path=$_cwd',
      );
      await tester.tap(find.widgetWithText(ListTile, 'main.dart'));
      await tester.pumpAndSettle();
      expect(find.byType(FileViewPage), findsOneWidget);
      expect(h.router.routeInformationProvider.value.uri.path, '/files');
      final pending = h.client.pendingRead = Completer();
      await tester.tap(find.widgetWithText(ListTile, 'README.md'));
      await tester.pump();
      h.router.go('/');
      await tester.pumpAndSettle();
      pending.complete({'text': '# late response'});
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await h.close(tester);
    },
  );

  testWidgets('wide git shows staged and all diffs beside the change list', (
    tester,
  ) async {
    final h = _Harness();
    await h.show(tester, const Size(1440, 900), location: '/git?cwd=$_cwd');
    await tester.tap(find.widgetWithText(ListTile, 'main.dart'));
    await tester.pumpAndSettle();
    expect(find.byType(DiffPage), findsOneWidget);
    expect(h.client.calls.last.params!['staged'], isTrue);
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is ListTile &&
            w.title is Text &&
            (w.title as Text).data == 'README.md',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('全部 diff'));
    await tester.pumpAndSettle();
    expect(h.client.calls.last.params!.containsKey('path'), isFalse);
    expect(tester.takeException(), isNull);
    await h.close(tester);
  });

  testWidgets('phone file selection navigates to its own page', (tester) async {
    final h = _Harness();
    await h.show(tester, const Size(390, 844), location: '/files?path=$_cwd');
    await tester.tap(find.widgetWithText(ListTile, 'main.dart'));
    await tester.pumpAndSettle();
    expect(find.byType(FileViewPage), findsOneWidget);
    expect(
      tester.widget<FileViewPage>(find.byType(FileViewPage)).path,
      '$_cwd/main.dart',
    );
    h.router.pop();
    await tester.pumpAndSettle();
    expect(find.byType(FileViewPage), findsNothing);
    expect(tester.takeException(), isNull);
    await h.close(tester);
  });

  testWidgets('unpaired desktop redirects to a bounded pairing form', (
    tester,
  ) async {
    final state = AppState(HostStore(), openSession: (_) {})..loaded = true;
    final router = createAppRouter(state, initialLocation: '/');
    addTearDown(() {
      router.dispose();
      state.dispose();
    });
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      AppScope(
        state: state,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PairPage), findsOneWidget);
    expect(
      tester.getSize(find.byType(TextField).first).width,
      lessThanOrEqualTo(560),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  final screenshots = Platform.environment['CODEAW_SCREENSHOTS'] == '1';
  testWidgets('desktop file, git and dialog previews', (tester) async {
    for (final font in {
      'Roboto':
          'D:/flutter/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
      'MaterialIcons':
          'D:/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      'NotoSansTC': 'C:/Windows/Fonts/NotoSansTC-VF.ttf',
      'monospace': 'C:/Windows/Fonts/consola.ttf',
    }.entries) {
      if (File(font.value).existsSync()) {
        final loader = FontLoader(font.key)
          ..addFont(
            Future.value(
              ByteData.sublistView(File(font.value).readAsBytesSync()),
            ),
          );
        await loader.load();
      }
    }
    final h = _Harness();
    await h.show(tester, const Size(1440, 900), location: '/files?path=$_cwd');
    await tester.tap(find.widgetWithText(ListTile, 'main.dart'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/workspace-files.png'),
    );
    h.router.go('/git?cwd=$_cwd');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'main.dart'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/workspace-git.png'),
    );
    h.router.go('/');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '建立新對話'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('screenshots/workspace-new-session.png'),
    );
    expect(tester.takeException(), isNull);
    await h.close(tester);
  }, skip: !screenshots);
  for (final preview in [
    (
      name: 'workspace-phone',
      size: const Size(390, 844),
      brightness: Brightness.light,
    ),
    (
      name: 'workspace-desktop',
      size: const Size(1440, 900),
      brightness: Brightness.light,
    ),
    (
      name: 'workspace-desktop-dark',
      size: const Size(1440, 900),
      brightness: Brightness.dark,
    ),
    (
      name: 'workspace-tablet',
      size: const Size(834, 1112),
      brightness: Brightness.light,
    ),
    (
      name: 'workspace-tablet-landscape',
      size: const Size(1024, 768),
      brightness: Brightness.light,
    ),
  ]) {
    testWidgets(preview.name, (tester) async {
      for (final font in {
        'Roboto':
            'D:/flutter/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
        'MaterialIcons':
            'D:/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        'NotoSansTC': 'C:/Windows/Fonts/NotoSansTC-VF.ttf',
        'monospace': 'C:/Windows/Fonts/consola.ttf',
      }.entries) {
        if (File(font.value).existsSync()) {
          final loader = FontLoader(font.key)
            ..addFont(
              Future.value(
                ByteData.sublistView(File(font.value).readAsBytesSync()),
              ),
            );
          await loader.load();
        }
      }
      final h = _Harness();
      await h.show(
        tester,
        preview.size,
        location: sessionRoute(_first),
        brightness: preview.brightness,
      );
      await tester.enterText(_input, '檢查視窗縮放後的版面，並保留尚未送出的訊息。');
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('screenshots/${preview.name}.png'),
      );
      expect(tester.takeException(), isNull);
      await h.close(tester);
    }, skip: !screenshots);
  }
}
