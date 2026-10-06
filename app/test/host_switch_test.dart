import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codeaw/app_state.dart';
import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/models.dart';
import 'package:codeaw/ui/pair/pair_page.dart';
import 'package:codeaw/ui/sessions/sessions_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

HostConfig _host(String name, {List<String>? urls, String? deviceId}) =>
    HostConfig(
      name: name,
      urls: urls ?? ['ws://$name:7860/acp'],
      token: 'test-token-$name',
      deviceId: deviceId ?? 'device-$name',
      deviceName: 'test-phone',
    );

class _Client extends BridgeClient {
  _Client(super.host) {
    status = ConnStatus.online;
    agents = [
      AgentInfo(id: host.name, name: 'Agent ${host.name}', status: 'ready'),
    ];
  }

  bool disposed = false;
  Completer<Map<String, dynamic>>? pendingList;

  @override
  void start() {}

  @override
  Future<dynamic> request(String method, [Map<String, dynamic>? params]) async {
    if (method == 'session/list') {
      if (pendingList != null) return pendingList!.future;
      return {
        'sessions': [
          {
            'sessionId': '${host.name}:1',
            'cwd': '/project',
            'title': '${host.name} conversation',
          },
        ],
      };
    }
    return {};
  }

  void preferUrls(List<String> urls) {
    host = host.withUrls(urls);
    notifyListeners();
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

class _FailingStore extends HostStore {
  bool fail = false;
  Completer<void>? blocked;

  @override
  Future<void> save(HostLibrary library) {
    if (fail) return Future.error(StateError('test storage failure'));
    if (blocked != null) {
      return blocked!.future.then((_) => super.save(library));
    }
    return super.save(library);
  }
}

AppState _state({HostStore? store}) => AppState(
  store ?? HostStore(),
  openSession: (_) {},
  createClient: _Client.new,
);

Future<GoRouter> _showHome(
  WidgetTester tester,
  AppState state, {
  bool preview = false,
}) async {
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => const SessionsPage()),
      GoRoute(path: '/pair', builder: (_, _) => const PairPage()),
    ],
  );
  addTearDown(router.dispose);
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    AppScope(
      state: state,
      child: MaterialApp.router(
        routerConfig: router,
        debugShowCheckedModeBanner: false,
        theme: preview
            ? ThemeData(
                useMaterial3: true,
                fontFamily: 'NotoSansTC',
                colorScheme: ColorScheme.fromSeed(
                  seedColor: const Color(0xFF0F9D8A),
                ),
              )
            : null,
      ),
    ),
  );
  await state.sessions!.refresh();
  await tester.pumpAndSettle();
  return router;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'existing single-computer pairing loads and survives adding a second computer',
    () async {
      final first = _host('first');
      FlutterSecureStorage.setMockInitialValues({
        'codeaw.host': jsonEncode(first.toJson()),
      });
      final state = _state();
      addTearDown(state.dispose);
      await state.load();
      expect(state.host!.name, 'first');
      expect(state.host!.token, first.token);

      await state.setHost(_host('second'));
      final saved = await HostStore().load();
      expect(saved.hosts.map((host) => host.name), ['first', 'second']);
      expect(saved.activeHost!.name, 'second');
    },
  );

  test(
    'switching isolates conversations and restores the last selected computer',
    () async {
      final state = _state();
      addTearDown(state.dispose);
      final first = _host('first');
      await state.setHost(first);
      await state.sessions!.refresh();
      final oldClient = state.client! as _Client;
      final oldHub = state.hub;
      final oldTerminals = state.terminals;
      expect(state.sessions!.sessions.single.title, 'first conversation');

      await state.setHost(_host('second'));
      expect(oldClient.disposed, isTrue);
      expect(state.hub, isNot(same(oldHub)));
      expect(state.terminals, isNot(same(oldTerminals)));
      expect(state.sessions!.sessions, isEmpty);
      await state.sessions!.refresh();
      expect(state.sessions!.sessions.single.title, 'second conversation');

      await state.setHost(state.hosts.first);
      expect(state.hosts, hasLength(2));
      final reopened = _state();
      addTearDown(reopened.dispose);
      await reopened.load();
      expect(reopened.host!.name, 'first');
      expect(reopened.host!.token, first.token);
    },
  );

  test(
    'pairing an existing endpoint replaces its pairing without adding a duplicate',
    () async {
      final state = _state();
      addTearDown(state.dispose);
      await state.setHost(
        _host(
          'first',
          urls: ['ws://first:7860/acp', 'wss://first.example/acp'],
        ),
      );
      await state.setHost(_host('second'));
      await state.setHost(
        _host(
          'renamed-first',
          urls: ['wss://first.example/acp'],
          deviceId: 'new-device',
        ),
      );
      expect(state.hosts.map((host) => host.name), ['renamed-first', 'second']);
      expect((await HostStore().load()).activeHost!.deviceId, 'new-device');
    },
  );

  test(
    'forgetting removes only the selected computer and falls back to a saved computer',
    () async {
      final state = _state();
      addTearDown(state.dispose);
      await state.setHost(_host('first'));
      await state.setHost(_host('second'));
      await state.forget();
      expect(state.host!.name, 'first');
      expect((await HostStore().load()).hosts.single.name, 'first');
      await state.forget();
      expect(state.paired, isFalse);
      expect(state.client, isNull);
      expect((await HostStore().load()).hosts, isEmpty);
    },
  );

  test(
    'remembering a working URL preserves other pairings and the active selection',
    () async {
      final state = _state();
      addTearDown(state.dispose);
      await state.setHost(_host('first'));
      await state.setHost(
        _host(
          'second',
          urls: ['ws://second:7860/acp', 'wss://second.example/acp'],
        ),
      );
      (state.client! as _Client).preferUrls([
        'wss://second.example/acp',
        'ws://second:7860/acp',
      ]);
      await state.setHost(state.hosts.first);
      final saved = await HostStore().load();
      expect(saved.activeHost!.name, 'first');
      expect(saved.hosts.last.urls.first, 'wss://second.example/acp');
    },
  );

  test(
    'a session list finishing after switching cannot update the new computer',
    () async {
      final state = _state();
      addTearDown(state.dispose);
      await state.setHost(_host('first'));
      final oldClient = state.client! as _Client;
      oldClient.pendingList = Completer();
      final refresh = state.sessions!.refresh();
      await state.setHost(_host('second'));
      oldClient.pendingList!.complete({'sessions': []});
      await refresh;
      expect(state.host!.name, 'second');
      expect(state.sessions!.sessions, isEmpty);
    },
  );

  test(
    'a URL update during selection cannot overwrite the saved active computer',
    () async {
      final store = _FailingStore();
      final state = _state(store: store);
      addTearDown(state.dispose);
      await state.setHost(_host('first'));
      await state.setHost(
        _host(
          'second',
          urls: ['ws://second:7860/acp', 'wss://second.example/acp'],
        ),
      );
      final oldClient = state.client! as _Client;
      store.blocked = Completer();
      final selection = state.setHost(state.hosts.first);
      oldClient.preferUrls([
        'wss://second.example/acp',
        'ws://second:7860/acp',
      ]);
      store.blocked!.complete();
      await selection;
      expect((await HostStore().load()).activeHost!.name, 'first');
    },
  );

  testWidgets(
    'top-left selector switches computer and resets the agent filter',
    (tester) async {
      final state = _state();
      addTearDown(state.dispose);
      await state.setHost(_host('first'));
      await state.setHost(_host('second'));
      await _showHome(tester, state);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Agent second'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('切換電腦'));
      await tester.pumpAndSettle();
      expect(find.text('目前電腦 · second:7860'), findsOneWidget);
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);

      await tester.tap(find.text('first'));
      await tester.pumpAndSettle();
      await state.sessions!.refresh();
      await tester.pumpAndSettle();
      expect(find.text('first · 已連線'), findsOneWidget);
      expect(find.text('first conversation'), findsOneWidget);
      expect(find.text('second conversation'), findsNothing);
      expect((await HostStore().load()).activeHost!.name, 'first');
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'adding a computer opens pairing and cancel keeps the current computer',
    (tester) async {
      final state = _state();
      addTearDown(state.dispose);
      await state.setHost(_host('first'));
      final router = await _showHome(tester, state);
      await tester.tap(find.byTooltip('切換電腦'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('新增電腦'));
      await tester.pumpAndSettle();
      expect(find.byType(PairPage), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();
      expect(find.byType(SessionsPage), findsOneWidget);
      expect(state.host!.name, 'first');
      expect(state.hosts, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'failed selection preserves the current connection and can be retried',
    (tester) async {
      final store = _FailingStore();
      final state = _state(store: store);
      addTearDown(state.dispose);
      await state.setHost(_host('first'));
      await state.setHost(_host('second'));
      await _showHome(tester, state);
      final currentClient = state.client;
      store.fail = true;
      await tester.tap(find.byTooltip('切換電腦'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('first'));
      await tester.pumpAndSettle();
      expect(find.text('無法切換電腦，請再試一次'), findsOneWidget);
      expect(state.client, same(currentClient));
      expect(state.host!.name, 'second');
      store.fail = false;
      await tester.tap(find.text('first'));
      await tester.pumpAndSettle();
      expect(state.host!.name, 'first');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'host selector phone preview',
    (tester) async {
      final font = FontLoader('NotoSansTC');
      font.addFont(
        Future.value(
          ByteData.sublistView(
            File('C:/Windows/Fonts/NotoSansTC-VF.ttf').readAsBytesSync(),
          ),
        ),
      );
      await font.load();
      final icons = FontLoader('MaterialIcons');
      icons.addFont(
        Future.value(
          ByteData.sublistView(
            File(
              '${Platform.environment['FLUTTER_ROOT'] ?? 'D:/flutter'}/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
            ).readAsBytesSync(),
          ),
        ),
      );
      await icons.load();
      final state = _state();
      addTearDown(state.dispose);
      await state.setHost(
        _host('office-pc', urls: ['ws://100.64.0.10:7860/acp']),
      );
      await state.setHost(
        _host('home-pc', urls: ['ws://100.64.0.20:7860/acp']),
      );
      await _showHome(tester, state, preview: true);
      await tester.tap(find.byTooltip('切換電腦'));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('screenshots/host-selector.png'),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    skip: Platform.environment['CODEAW_SCREENSHOTS'] != '1',
  );
}
