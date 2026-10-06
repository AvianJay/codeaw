import 'package:codeaw/app_state.dart';
import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/history_cache.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/models.dart';
import 'package:codeaw/data/session_controller.dart';
import 'package:codeaw/data/sessions_model.dart';
import 'package:codeaw/ui/chat/chat_page.dart';
import 'package:codeaw/ui/common/app_theme.dart';
import 'package:codeaw/ui/sessions/new_session_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _id = 'codex:no-project';
const _cwd = 'C:/codeaw/data/chats/56b11791-856a-499a-9c1a-00a8a2e1f478';
const _meta = {'cwd': _cwd, 'projectless': true, 'epoch': 'test', 'lastSeq': 0};

class _Storage implements HistoryStorage {
  final values = <String, Map<String, dynamic>>{};
  @override
  Future<Map<String, dynamic>?> read(String host, String session) async =>
      values['$host/$session'];
  @override
  Future<void> write(
    String host,
    String session,
    Map<String, dynamic> value,
  ) async {
    values['$host/$session'] = value;
  }

  @override
  Future<void> remove(String host, String session) async {
    values.remove('$host/$session');
  }

  @override
  Future<void> clear(String host) async {
    values.clear();
  }
}

class _Client extends BridgeClient {
  _Client()
    : super(
        HostConfig(
          name: 'PC',
          urls: ['ws://fixture/acp'],
          token: 'fixture',
          deviceId: 'fixture',
          deviceName: 'phone',
        ),
      ) {
    status = ConnStatus.online;
    supportsProjectless = true;
    agents = [AgentInfo(id: 'codex', name: 'Codex', status: 'ready')];
  }
  final calls = <({String method, Map<String, dynamic>? params})>[];
  String? projectRoot;
  bool created = false;
  @override
  void start() {}
  @override
  Future<dynamic> request(String method, [Map<String, dynamic>? params]) async {
    calls.add((method: method, params: params));
    if (method == '_codeaw/workspaces/list') {
      return {
        'roots': [
          if (projectRoot != null) {'path': projectRoot, 'source': 'config'},
        ],
      };
    }
    if (method == 'session/new') {
      created = true;
      return {
        'sessionId': _id,
        '_meta': {'codeaw': _meta},
      };
    }
    if (method == 'session/load') {
      return {
        '_meta': {'codeaw': _meta},
      };
    }
    if (method == 'session/list') {
      return {
        'sessions': [
          if (created)
            {
              'sessionId': _id,
              'cwd': _cwd,
              '_meta': {
                'codeaw': {..._meta, 'known': true},
              },
            },
        ],
      };
    }
    return {};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final size in [const Size(320, 640), const Size(390, 844), const Size(844, 390)]) {
    testWidgets(
      'starts no-project chat without a directory at $size and shows useful labels',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final client = _Client();
        final cache = HistoryCache(client.host, storage: _Storage());
        final state = AppState(HostStore(), openSession: (_) {})
          ..client = client
          ..host = client.host
          ..hub = SessionHub(client, cache: cache)
          ..sessions = SessionsModel(client, cache: cache);
        // A previous no-project folder must never become a recent project.
        state.sessions!.sessions = [
          SessionSummary(
            id: 'codex:old',
            agentId: 'codex',
            cwd: _cwd,
            projectless: true,
          ),
        ];
        final router = GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (context, _) => Scaffold(
                body: TextButton(
                  onPressed: () => showNewSessionSheet(context),
                  child: const Text('建立聊天'),
                ),
              ),
            ),
            GoRoute(
              path: '/session',
              builder: (_, route) => ChatPage(
                sessionId: route.uri.queryParameters['id']!,
                cwd: route.uri.queryParameters['cwd'],
              ),
            ),
          ],
        );
        await tester.pumpWidget(
          AppScope(
            state: state,
            child: MaterialApp.router(
              routerConfig: router,
              theme: codeawTheme(Brightness.light),
            ),
          ),
        );
        await tester.tap(find.text('建立聊天'));
        await tester.pumpAndSettle();
        expect(find.text(folderName(_cwd)), findsNothing);
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '開始'))
              .onPressed,
          isNull,
        );
        await tester.tap(find.text('無專案聊天'));
        await tester.pumpAndSettle();
        expect(find.text('瀏覽…'), findsNothing);
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '開始'))
              .onPressed,
          isNotNull,
        );
        await tester.ensureVisible(find.text('開始'));
        await tester.tap(find.text('開始'));
        await tester.pumpAndSettle();
        final params = client.calls
            .singleWhere((call) => call.method == 'session/new')
            .params!;
        expect(params['cwd'], '');
        expect((params['_meta'] as Map)['codeaw'], {
          'agentId': 'codex',
          'projectless': true,
        });
        expect(state.hub!.peek(_id)!.cwd, _cwd);
        expect(state.hub!.peek(_id)!.projectless, isTrue);
        expect(find.text('無專案'), findsOneWidget);
        expect(find.text('Codex · 無專案'), findsOneWidget);
        expect(find.text(folderName(_cwd)), findsNothing);
        await tester.tap(find.byType(PopupMenuButton<String>));
        await tester.pumpAndSettle();
        expect(find.text('Git 變更'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        router.dispose();
        state.dispose();
      },
    );
  }

  testWidgets(
    'older bridge explains update requirement and keeps normal project creation available',
    (tester) async {
      final client = _Client()
        ..supportsProjectless = false
        ..projectRoot = 'C:/project';
      final state = AppState(HostStore(), openSession: (_) {})..client = client;
      await tester.pumpWidget(
        AppScope(
          state: state,
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showNewSessionSheet(context),
                  child: const Text('建立聊天'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('建立聊天'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '開始'))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.text('無專案聊天'));
      await tester.pumpAndSettle();
      expect(find.text('請先更新電腦上的 bridge，才能使用無專案聊天。'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '開始'))
            .onPressed,
        isNull,
      );
      expect(
        client.calls.where((call) => call.method == 'session/new'),
        isEmpty,
      );
      await tester.tap(find.text('專案'));
      await tester.pumpAndSettle();
      expect(find.text('project'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '開始'))
            .onPressed,
        isNotNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );

  test(
    'controller and list retain no-project metadata after an offline cache restore',
    () async {
      final client = _Client()..created = true;
      final cache = HistoryCache(client.host, storage: _Storage());
      final hub = SessionHub(client, cache: cache);
      final first = hub.adopt(_id, '', {
        '_meta': {'codeaw': _meta},
      });
      await first.persist();
      final list = SessionsModel(client, cache: cache);
      await list.refresh();
      await list.persist();
      expect(list.sessions.single.displayTitle, '無專案');
      hub.dispose();
      list.dispose();
      client.status = ConnStatus.offline;
      final restored = SessionController(client, _id, cache: cache);
      await restored.attach();
      expect(restored.cwd, _cwd);
      expect(restored.projectless, isTrue);
      expect(restored.displayLocation, '無專案');
      final restoredList = SessionsModel(client, cache: cache);
      await restoredList.restore();
      expect(restoredList.sessions.single.projectless, isTrue);
      expect(restoredList.sessions.single.displayTitle, '無專案');
      restored.dispose();
      restoredList.dispose();
      client.dispose();
    },
  );
}
