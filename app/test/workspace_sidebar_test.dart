import 'dart:async';

import 'package:codeaw/app_state.dart';
import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/history_cache.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/models.dart';
import 'package:codeaw/data/session_controller.dart';
import 'package:codeaw/data/sessions_model.dart';
import 'package:codeaw/ui/workspace/workspace_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Storage implements HistoryStorage {
  @override
  Future<Map<String, dynamic>?> read(String host, String session) async => null;
  @override
  Future<void> write(String host, String session, Map<String, dynamic> value) async {}
  @override
  Future<void> remove(String host, String session) async {}
  @override
  Future<void> clear(String host) async {}
}

class _Client extends BridgeClient {
  _Client()
    : super(HostConfig(name: 'PC', urls: ['ws://fixture/acp'], token: 'fixture', deviceId: 'fixture', deviceName: 'pad')) {
    status = ConnStatus.online;
    agents = [AgentInfo(id: 'claude', name: 'Claude Code', status: 'ready')];
  }
  final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  @override
  Stream<Map<String, dynamic>> get activity => events.stream;
  @override
  void start() {}
  @override
  Future<dynamic> request(String method, [Map<String, dynamic>? params]) async => method == 'session/list'
      ? {
          'sessions': [
            {'sessionId': 'claude:a', 'cwd': '/p', 'title': '側邊欄裡的對話', 'updatedAt': DateTime.now().toUtc().toIso8601String()},
          ],
        }
      : <String, dynamic>{};

  @override
  void dispose() {
    unawaited(events.close());
    super.dispose();
  }
}

Future<AppState> _show(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final client = _Client();
  final cache = HistoryCache(client.host, storage: _Storage());
  final app = AppState(HostStore(), openSession: (_) {})
    ..client = client
    ..host = client.host
    ..hub = SessionHub(client, cache: cache)
    ..sessions = SessionsModel(client, cache: cache);
  await app.sessions!.refresh();
  await tester.pumpWidget(
    AppScope(
      state: app,
      child: MaterialApp(
        home: WorkspaceShell(
          location: Uri.parse('/session?id=claude:a'),
          child: const Center(child: Text('chat content')),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return app;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('an iPad in landscape can hide the sidebar, bring it back, and it stays hidden next time', (tester) async {
    // iPad Pro 11" landscape: wide enough for the permanent sidebar.
    final app = await _show(tester, const Size(1210, 834));
    final content = find.byKey(const ValueKey('workspace-content'));
    final open = tester.getSize(content).width;
    expect(find.text('側邊欄裡的對話'), findsOneWidget);
    expect(open, lessThan(1210 - 290));

    await tester.tap(find.byTooltip('收合側邊欄'));
    await tester.pumpAndSettle();
    expect(find.text('側邊欄裡的對話'), findsNothing);
    expect(find.text('chat content'), findsOneWidget);
    expect(tester.getSize(content).width, greaterThan(open + 200));
    // What is left is a narrow strip that still starts a chat.
    expect(find.byTooltip('新對話'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('展開側邊欄'));
    await tester.pumpAndSettle();
    expect(find.text('側邊欄裡的對話'), findsOneWidget);
    expect(tester.getSize(content).width, open);

    await tester.tap(find.byTooltip('收合側邊欄'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    app.dispose();
    final again = await _show(tester, const Size(1210, 834));
    expect(find.text('側邊欄裡的對話'), findsNothing);
    expect(find.byTooltip('展開側邊欄'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    again.dispose();
  });

  testWidgets('narrower tablets keep their rail and drawer, with no collapse button', (tester) async {
    final app = await _show(tester, const Size(834, 1194));
    expect(find.byTooltip('收合側邊欄'), findsNothing);
    expect(find.byTooltip('展開側邊欄'), findsNothing);
    expect(find.text('對話'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });
}
