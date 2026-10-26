import 'dart:async';

import 'package:codeaw/acp/jsonrpc.dart';
import 'package:codeaw/app_state.dart';
import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/history_cache.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/models.dart';
import 'package:codeaw/data/session_controller.dart';
import 'package:codeaw/data/sessions_model.dart';
import 'package:codeaw/ui/sessions/new_session_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _cwd = 'D:/project';
const _methods = [
  {'id': 'oauth-personal', 'name': 'Log in with Google'},
  {'id': 'oauth-business', 'name': 'Log in with Gemini Enterprise'},
  {'id': 'gemini-api-key', 'name': 'Gemini API key'},
  {'id': 'agent-platform', 'name': 'Gemini Enterprise Agent Platform'},
];

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
    agents = [
      AgentInfo(id: 'antigravity', name: 'Google Antigravity', status: 'ready'),
      AgentInfo(id: 'codex', name: 'Codex', status: 'ready'),
    ];
  }

  final calls = <({String method, Map<String, dynamic>? params})>[];
  bool authenticated = false;
  bool failAuth = false;
  bool legacy = false;
  Completer<void>? pendingAuth;
  RpcError? sessionError;

  @override
  void start() {}

  @override
  Future<dynamic> request(String method, [Map<String, dynamic>? params]) async {
    calls.add((method: method, params: params));
    if (method == '_codeaw/workspaces/list') {
      return {
        'roots': [
          {'path': _cwd, 'source': 'config'},
        ],
      };
    }
    if (method == 'session/new') {
      if (sessionError != null) throw sessionError!;
      final agentId = (params!['_meta'] as Map)['codeaw']['agentId'];
      if (agentId == 'antigravity' && !authenticated) {
        throw RpcError(
          RpcError.authRequired,
          'Authentication required: No authentication method selected. private-provider-diagnostics',
          legacy
              ? null
              : {
                  'codeaw': {'agentId': agentId, 'authMethods': _methods},
                },
        );
      }
      return {
        'sessionId': '$agentId:new',
        '_meta': {
          'codeaw': {'cwd': _cwd},
        },
      };
    }
    if (method == '_codeaw/agents/authenticate') {
      if (pendingAuth != null) await pendingAuth!.future;
      if (failAuth) {
        throw RpcError(RpcError.authRequired, 'Authentication required', {
          'codeaw': {
            'agentId': 'antigravity',
            'authMethods': _methods,
            'authFailed': true,
          },
        });
      }
      authenticated = true;
      return {};
    }
    if (method == 'session/list') return {'sessions': []};
    return {};
  }
}

class _Harness {
  final client = _Client();
  late final AppState state;
  late final GoRouter router;

  Future<void> open(
    WidgetTester tester, [
    Size size = const Size(390, 844),
  ]) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final cache = HistoryCache(client.host, storage: _Storage());
    state = AppState(HostStore(), openSession: (_) {})
      ..client = client
      ..host = client.host
      ..hub = SessionHub(client, cache: cache)
      ..sessions = SessionsModel(client, cache: cache);
    router = GoRouter(
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
          builder: (_, _) => const Scaffold(body: Text('對話已建立')),
        ),
      ],
    );
    await tester.pumpWidget(
      AppScope(
        state: state,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.tap(find.text('建立聊天'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('開始'));
    await tester.tap(find.text('開始'));
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose();
    state.dispose();
  }
}

void main() {
  for (final size in [
    const Size(320, 640),
    const Size(390, 844),
    const Size(844, 390),
    const Size(1100, 700),
  ]) {
    testWidgets('selects authentication and retries the same chat at $size', (
      tester,
    ) async {
      final h = _Harness();
      await h.open(tester, size);
      expect(find.text('請選擇登入方式，再開始對話。'), findsOneWidget);
      expect(find.textContaining('private-provider-diagnostics'), findsNothing);
      expect(find.text('Google 帳號'), findsOneWidget);
      await tester.ensureVisible(find.text('Gemini API 金鑰'));
      await tester.tap(find.text('Gemini API 金鑰'));
      await tester.pumpAndSettle();
      expect(find.text('使用電腦上的 GEMINI_API_KEY 設定。'), findsOneWidget);
      await tester.ensureVisible(find.text('登入並開始'));
      await tester.tap(find.text('登入並開始'));
      await tester.pumpAndSettle();
      expect(find.text('對話已建立'), findsOneWidget);
      expect(
        h.client.calls
            .where((c) => c.method == '_codeaw/agents/authenticate')
            .single
            .params,
        {'agentId': 'antigravity', 'methodId': 'gemini-api-key'},
      );
      final sessions = h.client.calls
          .where((c) => c.method == 'session/new')
          .toList();
      expect(sessions, hasLength(2));
      expect(sessions.last.params, sessions.first.params);
      expect(h.state.hub!.peek('antigravity:new'), isNotNull);
      expect(tester.takeException(), isNull);
      await h.close(tester);
    });
  }

  testWidgets(
    'waits for login before creating a chat and disables conflicting controls',
    (tester) async {
      final h = _Harness();
      await h.open(tester);
      h.client.pendingAuth = Completer<void>();
      await tester.ensureVisible(find.text('登入並開始'));
      await tester.tap(find.text('登入並開始'));
      await tester.pump();
      expect(
        h.client.calls.where((c) => c.method == 'session/new'),
        hasLength(1),
      );
      for (final chip in tester.widgetList<ChoiceChip>(
        find.byType(ChoiceChip),
      )) {
        expect(chip.onSelected, isNull);
      }
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '瀏覽…'))
            .onPressed,
        isNull,
      );
      h.client.pendingAuth!.complete();
      await tester.pumpAndSettle();
      expect(find.text('對話已建立'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await h.close(tester);
    },
  );

  testWidgets('failed login keeps the method choices available for retry', (
    tester,
  ) async {
    final h = _Harness();
    await h.open(tester);
    h.client.failAuth = true;
    await tester.ensureVisible(find.text('登入並開始'));
    await tester.tap(find.text('登入並開始'));
    await tester.pumpAndSettle();
    expect(find.text('登入未完成。請在電腦上確認登入或 API 金鑰設定後重試。'), findsOneWidget);
    expect(
      h.client.calls.where((c) => c.method == 'session/new'),
      hasLength(1),
    );
    h.client.failAuth = false;
    await tester.ensureVisible(find.text('Gemini API 金鑰'));
    await tester.tap(find.text('Gemini API 金鑰'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('登入並開始'));
    await tester.tap(find.text('登入並開始'));
    await tester.pumpAndSettle();
    expect(find.text('對話已建立'), findsOneWidget);
    await h.close(tester);
  });

  testWidgets('switching agents clears the previous authentication selection', (
    tester,
  ) async {
    final h = _Harness();
    await h.open(tester);
    await tester.ensureVisible(find.text('Codex'));
    await tester.tap(find.text('Codex'));
    await tester.pumpAndSettle();
    expect(find.text('Google 帳號'), findsNothing);
    expect(find.text('登入並開始'), findsNothing);
    await tester.ensureVisible(find.text('開始'));
    await tester.tap(find.text('開始'));
    await tester.pumpAndSettle();
    expect(find.text('對話已建立'), findsOneWidget);
    expect(
      h.client.calls.where((c) => c.method == '_codeaw/agents/authenticate'),
      isEmpty,
    );
    await h.close(tester);
  });

  testWidgets(
    'older auth errors show concise guidance without provider diagnostics',
    (tester) async {
      final h = _Harness()..client.legacy = true;
      await h.open(tester);
      expect(find.text('此 Agent 需要登入。請在電腦上完成登入後重試。'), findsOneWidget);
      expect(find.textContaining('private-provider-diagnostics'), findsNothing);
      expect(find.text('登入並開始'), findsNothing);
      await h.close(tester);
    },
  );

  testWidgets(
    'unrelated errors keep their original details and offer no login',
    (tester) async {
      final h = _Harness()
        ..client.sessionError = RpcError(-32602, 'Workspace unavailable');
      await h.open(tester);
      expect(find.text('Workspace unavailable'), findsOneWidget);
      expect(find.text('登入並開始'), findsNothing);
      await h.close(tester);
    },
  );
}
