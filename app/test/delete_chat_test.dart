import 'dart:async';

import 'package:codeaw/acp/jsonrpc.dart';
import 'package:codeaw/app_state.dart';
import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/history_cache.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/models.dart';
import 'package:codeaw/data/session_controller.dart';
import 'package:codeaw/data/sessions_model.dart';
import 'package:codeaw/ui/chat/chat_page.dart';
import 'package:codeaw/ui/sessions/sessions_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _Storage implements HistoryStorage {
  final values = <String, Map<String, dynamic>>{};
  String key(String host, String session) => '$host/$session';
  @override
  Future<Map<String, dynamic>?> read(String host, String session) async =>
      values[key(host, session)];
  @override
  Future<void> write(
    String host,
    String session,
    Map<String, dynamic> value,
  ) async {
    values[key(host, session)] = value;
  }

  @override
  Future<void> remove(String host, String session) async {
    values.remove(key(host, session));
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
    agents = [AgentInfo(id: 'codex', name: 'Codex', status: 'ready')];
  }
  final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final calls = <String>[];
  bool failDelete = false;
  String state = 'idle';
  @override
  Stream<Map<String, dynamic>> get activity => events.stream;
  @override
  void start() {}
  @override
  Future<dynamic> request(String method, [Map<String, dynamic>? params]) async {
    calls.add(method);
    if (method == 'session/list') {
      return {
        'sessions': [
          {
            'sessionId': 'codex:one',
            'cwd': 'C:/project',
            'title': '要刪除的聊天',
            '_meta': {
              'codeaw': {'state': state, 'connection': 'desktop'},
            },
          },
          {'sessionId': 'codex:two', 'cwd': 'C:/project', 'title': '保留聊天'},
        ],
      }; // A stale in-flight list must never resurrect a successfully deleted row.
    }
    if (method == 'session/load') {
      return {
        '_meta': {
          'codeaw': {
            'epoch': 'fixture',
            'lastSeq': 1,
            'state': state,
            'connection': 'desktop',
          },
        },
      };
    }
    if (method == 'session/delete') {
      if (failDelete) throw RpcError(-32600, 'Chat is busy');
      events.add({'sessionId': params!['sessionId'], 'deleted': true});
    }
    return {};
  }

  @override
  void dispose() {
    unawaited(events.close());
    super.dispose();
  }
}

Future<({AppState app, _Client client, HistoryCache cache, GoRouter router})>
_show(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  bool chat = false,
  String state = 'idle',
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final client = _Client()..state = state;
  final cache = HistoryCache(client.host, storage: _Storage());
  final app = AppState(HostStore(), openSession: (_) {})
    ..client = client
    ..host = client.host
    ..hub = SessionHub(client, cache: cache)
    ..sessions = SessionsModel(client, cache: cache);
  await app.sessions!.refresh();
  app.hub!.adopt('codex:one', 'C:/project', {
    '_meta': {
      'codeaw': {'epoch': 'fixture', 'lastSeq': 1},
    },
  });
  await app.hub!.persist();
  await app.sessions!.persist();
  final router = GoRouter(
    initialLocation: chat ? '/session?id=codex:one' : '/',
    routes: [
      GoRoute(path: '/', builder: (_, _) => const SessionsPage()),
      GoRoute(
        path: '/session',
        builder: (_, s) => ChatPage(
          sessionId: s.uri.queryParameters['id']!,
          cwd: 'C:/project',
        ),
      ),
    ],
  );
  await tester.pumpWidget(
    AppScope(
      state: app,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
    router.dispose();
  });
  return (app: app, client: client, cache: cache, router: router);
}

void main() {
  for (final size in [
    const Size(320, 640),
    const Size(390, 844),
    const Size(844, 390),
  ]) {
    testWidgets(
      'list deletion requires confirmation and stays deleted at $size',
      (tester) async {
        final fixture = await _show(tester, size: size);
        await tester.tap(find.byTooltip('刪除聊天').first);
        await tester.pumpAndSettle();
        expect(find.text('刪除聊天？'), findsOneWidget);
        expect(find.textContaining('Codex 桌面上的對話會保留'), findsOneWidget);
        expect(
          fixture.client.calls.where((s) => s == 'session/delete'),
          isEmpty,
        );
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(fixture.app.sessions!.byId('codex:one'), isNotNull);
        await tester.tap(find.byTooltip('刪除聊天').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('刪除'));
        await tester.pumpAndSettle();
        expect(
          fixture.client.calls.where((s) => s == 'session/delete'),
          hasLength(1),
        );
        expect(fixture.app.sessions!.byId('codex:one'), isNull);
        expect(fixture.app.hub!.peek('codex:one'), isNull);
        await tester.pump(const Duration(seconds: 3));
        expect(await fixture.cache.read('codex:one'), isNull);
        await fixture.app.sessions!.refresh();
        await fixture.app.sessions!.persist();
        expect(fixture.app.sessions!.byId('codex:one'), isNull);
        expect(fixture.app.sessions!.byId('codex:two'), isNotNull);
        final reopened = SessionsModel(fixture.client, cache: fixture.cache);
        await reopened.restore();
        expect(reopened.byId('codex:one'), isNull);
        expect(reopened.byId('codex:two'), isNotNull);
        reopened.dispose();
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('failed deletion preserves the chat and cached history', (
    tester,
  ) async {
    final fixture = await _show(tester);
    fixture.client.failDelete = true;
    await tester.tap(find.byTooltip('刪除聊天').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('刪除'));
    await tester.pumpAndSettle();
    expect(find.textContaining('無法刪除聊天'), findsOneWidget);
    expect(fixture.app.sessions!.byId('codex:one'), isNotNull);
    expect(await fixture.cache.read('codex:one'), isNotNull);
    expect(fixture.app.sessions!.isDeleting('codex:one'), isFalse);
  });
  testWidgets('chat menu confirms deletion and returns to the chat list', (
    tester,
  ) async {
    final fixture = await _show(tester, chat: true);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('刪除聊天'));
    await tester.pumpAndSettle();
    expect(fixture.client.calls.where((s) => s == 'session/delete'), isEmpty);
    await tester.tap(find.text('刪除'));
    await tester.pumpAndSettle();
    expect(fixture.router.routeInformationProvider.value.uri.path, '/');
    expect(fixture.app.sessions!.byId('codex:one'), isNull);
    expect(await fixture.cache.read('codex:one'), isNull);
    expect(tester.takeException(), isNull);
  });
  testWidgets('running chat cannot be deleted from the list', (tester) async {
    final fixture = await _show(tester, state: 'running');
    final button = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.delete_outline_rounded).first,
    );
    expect(button.onPressed, isNull);
    expect(fixture.client.calls.where((s) => s == 'session/delete'), isEmpty);
  });
}
