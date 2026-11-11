import 'dart:async';

import 'package:codeaw/app_state.dart';
import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/history_cache.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/models.dart';
import 'package:codeaw/data/session_controller.dart';
import 'package:codeaw/data/sessions_model.dart';
import 'package:codeaw/ui/sessions/session_groups.dart';
import 'package:codeaw/ui/sessions/sessions_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Storage implements HistoryStorage {
  final values = <String, Map<String, dynamic>>{};
  @override
  Future<Map<String, dynamic>?> read(String host, String session) async => values['$host/$session'];
  @override
  Future<void> write(String host, String session, Map<String, dynamic> value) async {
    values['$host/$session'] = value;
  }

  @override
  Future<void> remove(String host, String session) async {
    values.remove('$host/$session');
  }

  @override
  Future<void> clear(String host) async => values.clear();
}

class _Client extends BridgeClient {
  _Client(this.listed)
    : super(HostConfig(name: 'PC', urls: ['ws://fixture/acp'], token: 'fixture', deviceId: 'fixture', deviceName: 'phone')) {
    status = ConnStatus.online;
    agents = [AgentInfo(id: 'claude', name: 'Claude Code', status: 'ready')];
  }
  final List<Map<String, dynamic>> listed;
  final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  @override
  Stream<Map<String, dynamic>> get activity => events.stream;
  @override
  void start() {}
  @override
  Future<dynamic> request(String method, [Map<String, dynamic>? params]) async =>
      method == 'session/list' ? {'sessions': listed} : <String, dynamic>{};

  @override
  void dispose() {
    unawaited(events.close());
    super.dispose();
  }
}

SessionSummary _session(String id, DateTime? at) =>
    SessionSummary(id: 'claude:$id', agentId: 'claude', cwd: '/p', title: id, updatedAt: at);

void main() {
  final now = DateTime(2026, 11, 11, 18, 30);

  test('labels conversations by local calendar day', () {
    expect(sessionDateLabel(DateTime(2026, 11, 11, 0, 1), now), '今天');
    expect(sessionDateLabel(now.add(const Duration(minutes: 3)), now), '今天');
    expect(sessionDateLabel(DateTime(2026, 11, 10, 23, 59), now), '昨天');
    expect(sessionDateLabel(DateTime(2026, 11, 9, 12), now), '過去 7 天');
    expect(sessionDateLabel(DateTime(2026, 11, 5, 0, 0), now), '過去 7 天');
    expect(sessionDateLabel(DateTime(2026, 11, 4, 23), now), '過去 30 天');
    expect(sessionDateLabel(DateTime(2026, 10, 13, 9), now), '過去 30 天');
    expect(sessionDateLabel(DateTime(2026, 10, 12, 9), now), '10 月');
    expect(sessionDateLabel(DateTime(2025, 12, 31), now), '2025 年 12 月');
    expect(sessionDateLabel(null, now), '更早');
    // Times arrive in UTC; the day is the device's.
    expect(sessionDateLabel(DateTime.utc(2026, 11, 11, 10).toLocal().toUtc(), now), sessionDateLabel(DateTime.utc(2026, 11, 11, 10).toLocal(), now));
  });

  test('groups newest first and keeps each day together', () {
    final groups = groupSessionsByDate([
      _session('old', DateTime(2026, 9, 1)),
      _session('yesterday', DateTime(2026, 11, 10, 8)),
      _session('unknown', null),
      _session('noon', DateTime(2026, 11, 11, 12)),
      _session('morning', DateTime(2026, 11, 11, 7)),
      _session('week', DateTime(2026, 11, 7)),
    ], now);
    expect(groups.map((g) => g.label), ['今天', '昨天', '過去 7 天', '9 月', '更早']);
    expect(groups.first.sessions.map((s) => s.title), ['noon', 'morning']);
  });

  testWidgets('session list shows a heading per day instead of one recent list', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final today = DateTime.now();
    String at(Duration ago) => today.subtract(ago).toUtc().toIso8601String();
    final client = _Client([
      {'sessionId': 'claude:a', 'cwd': '/p', 'title': '剛問的', 'updatedAt': at(const Duration(seconds: 5))},
      {'sessionId': 'claude:b', 'cwd': '/p', 'title': '上個月的', 'updatedAt': at(const Duration(days: 200))},
      {'sessionId': 'claude:c', 'cwd': '/p', 'title': '執行中的', 'updatedAt': at(const Duration(days: 3)),
        '_meta': {'codeaw': {'state': 'running'}}},
    ]);
    final cache = HistoryCache(client.host, storage: _Storage());
    final app = AppState(HostStore(), openSession: (_) {})
      ..client = client
      ..host = client.host
      ..hub = SessionHub(client, cache: cache)
      ..sessions = SessionsModel(client, cache: cache);
    await app.sessions!.refresh();
    await tester.pumpWidget(AppScope(state: app, child: const MaterialApp(home: SessionsPage())));
    await tester.pump();

    expect(find.text('最近對話'), findsNothing);
    expect(find.text('進行中'), findsOneWidget);
    expect(find.text('今天'), findsOneWidget);
    // A running chat stays under 進行中 and adds no day heading of its own.
    expect(find.text('過去 7 天'), findsNothing);
    final running = tester.getTopLeft(find.text('執行中的')).dy;
    final recent = tester.getTopLeft(find.text('剛問的')).dy;
    final old = tester.getTopLeft(find.text('上個月的')).dy;
    expect(running < recent && recent < old, isTrue);
    expect(tester.getTopLeft(find.text('今天')).dy, lessThan(recent));
    expect(find.textContaining('剛剛'), findsOneWidget);

    // A turn finishing elsewhere moves the chat without a manual refresh.
    client.events.add({'sessionId': 'claude:b', 'state': 'idle', 'updatedAt': at(Duration.zero)});
    await tester.pump();
    expect(tester.getTopLeft(find.text('上個月的')).dy, lessThan(tester.getTopLeft(find.text('剛問的')).dy));

    await tester.pumpWidget(const SizedBox());
    await app.sessions!.persist();
    app.sessions!.dispose();
    app.hub!.dispose();
    client.dispose();
  });
}
