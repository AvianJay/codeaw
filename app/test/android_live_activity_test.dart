import 'dart:async';

import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/android_live_activity.dart';
import 'package:codeaw/data/models.dart';
import 'package:codeaw/data/session_controller.dart';
import 'package:codeaw/data/sessions_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Client extends BridgeClient {
  _Client()
    : super(
        HostConfig(
          name: 'test',
          urls: ['ws://localhost:1'],
          token: 'test',
          deviceId: 'test',
          deviceName: 'test',
        ),
      ) {
    status = ConnStatus.online;
    agents = [AgentInfo(id: 'claude', name: 'Claude Code', status: 'ready')];
  }

  final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final updates = StreamController<SessionMessage>.broadcast(sync: true);
  List<Map<String, dynamic>> listed = [];

  @override
  Stream<Map<String, dynamic>> get activity => events.stream;

  @override
  Stream<SessionMessage> get messages => updates.stream;

  @override
  void start() {}

  @override
  Future<dynamic> request(
    String method, [
    Map<String, dynamic>? params,
  ]) async => method == 'session/list' ? {'sessions': listed} : {};

  /// `_codeaw/activity` for a listed conversation.
  void state(String id, String state, {int queued = 0}) =>
      events.add({'sessionId': id, 'state': state, 'queued': queued});

  void goOffline() {
    status = ConnStatus.offline;
    notifyListeners();
  }

  @override
  void dispose() {
    events.close();
    updates.close();
    super.dispose();
  }
}

class _Channel extends LiveActivityChannel {
  final sent = <Map<String, Object?>?>[];

  @override
  bool get platformSupported => true;

  @override
  Future<LiveActivitySupport> support() async =>
      const LiveActivitySupport(available: true, allowed: true);

  @override
  Future<void> show(Map<String, Object?>? content) async => sent.add(content);

  String? get sessionId =>
      sent.isEmpty ? null : sent.last?['sessionId'] as String?;
}

Map<String, dynamic> _listed(String id, String state, {String? title}) => {
  'sessionId': id,
  'cwd': '/projects/${id.split(':').last}',
  'title': ?title,
  '_meta': {
    'codeaw': {'state': state},
  },
};

class _Harness {
  final client = _Client();
  final channel = _Channel();
  late final hub = SessionHub(client);
  late final sessions = SessionsModel(client);
  late final tracker = LiveActivityTracker(channel: channel);
  var _seq = 0;

  Future<void> setUp(
    List<Map<String, dynamic>> listed, {
    bool enabled = true,
  }) async {
    client.listed = listed;
    await sessions.refresh();
    await tracker.refreshSupport();
    if (enabled) await tracker.setEnabled(true);
    tracker.bind(client, sessions, hub);
  }

  void event(String id, Map<String, dynamic> event) => client.updates.add(
    SessionMessage('_codeaw/event', {
      'sessionId': id,
      'event': event,
      '_meta': {
        'codeaw': {'seq': ++_seq},
      },
    }),
  );

  void update(String id, Map<String, dynamic> update) => client.updates.add(
    SessionMessage('session/update', {
      'sessionId': id,
      'update': update,
      '_meta': {
        'codeaw': {'seq': ++_seq},
      },
    }),
  );

  /// The conversation opened on this device, mid-turn.
  SessionController open(String id, {List<String> plan = const []}) {
    final c = hub.adopt(id, '/projects/${id.split(':').last}', {});
    event(id, {
      'type': 'state',
      'state': 'running',
      'queued': 0,
      'turnStartedAt': 1700000000000,
      'turnPromptId': 'p1',
    });
    update(id, {
      'sessionUpdate': 'tool_call',
      'toolCallId': 't1',
      'title': 'Run flutter test',
      'kind': 'execute',
      'status': 'in_progress',
    });
    if (plan.isNotEmpty) {
      update(id, {
        'sessionUpdate': 'plan',
        'entries': [
          for (final status in plan)
            {'content': status, 'priority': 'medium', 'status': status},
        ],
      });
    }
    return c;
  }

  // Inside the test body: pending timers fail a widget test before tear-downs run.
  void dispose() {
    tracker.dispose();
    hub.dispose();
    sessions.dispose();
    client.dispose();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('arms the conversation on screen with its turn details', (
    tester,
  ) async {
    final h = _Harness();
    await h.setUp([
      _listed('claude:a', 'running', title: 'Fix tests'),
      _listed('claude:b', 'running'),
    ]);
    h.open('claude:a', plan: ['completed', 'in_progress', 'pending']);
    await tester.pump(const Duration(milliseconds: 60));
    expect(
      h.channel.sent,
      isEmpty,
      reason: 'two conversations run and none is on screen',
    );

    h.tracker.viewing = 'claude:a';
    expect(h.channel.sent.single, {
      'sessionId': 'claude:a',
      'link': 'codeaw://session/claude%3Aa',
      'agent': 'Claude Code',
      'title': 'Fix tests',
      'phase': 'running',
      'detail': 'Run flutter test',
      'startedAt': 1700000000000,
      'steps': ['completed', 'in_progress', 'pending'],
    });
    await tester.pump(const Duration(seconds: 1));
    h.dispose();
  });

  testWidgets('falls back to the only running conversation', (tester) async {
    final h = _Harness();
    await h.setUp([
      _listed('claude:a', 'idle'),
      _listed('claude:b', 'running'),
    ]);
    h.tracker.viewing = 'claude:a';
    expect(h.channel.sessionId, 'claude:b');
    expect(
      h.channel.sent.last?['title'],
      'b',
      reason: 'untitled conversations use their folder',
    );
    expect(
      h.channel.sent.last?['detail'],
      '執行中…',
      reason: 'not open on this device',
    );

    h.client.state('claude:a', 'running');
    await tester.pump(const Duration(seconds: 1));
    expect(
      h.channel.sessionId,
      'claude:a',
      reason: 'the conversation on screen wins once it runs',
    );

    h.tracker.viewing = null;
    expect(
      h.channel.sent.last,
      isNull,
      reason: 'two run and none is on screen',
    );
    await tester.pump(const Duration(seconds: 1));
    h.dispose();
  });

  testWidgets(
    'follows the same conversation in the background until its turn ends',
    (tester) async {
      final h = _Harness();
      await h.setUp([
        _listed('claude:a', 'running'),
        _listed('claude:b', 'idle'),
      ]);
      h.open('claude:a');
      h.tracker.viewing = 'claude:a';
      await tester.pump(const Duration(seconds: 1));

      h.tracker.visible = false;
      h.tracker.viewing = null;
      h.client.state('claude:b', 'running');
      await tester.pump(const Duration(seconds: 1));
      expect(
        h.channel.sessionId,
        'claude:a',
        reason: 'no other conversation is picked up while hidden',
      );

      h.event('claude:a', {
        'type': 'state',
        'state': 'requires_action',
        'queued': 0,
        'turnStartedAt': 1700000000000,
      });
      await tester.pump(const Duration(seconds: 1));
      expect(h.channel.sent.last, containsPair('phase', 'approval'));
      expect(h.channel.sent.last?['detail'], '需要你的批准');

      h.event('claude:a', {
        'type': 'state',
        'state': 'idle',
        'queued': 0,
        'stopReason': 'end_turn',
      });
      await tester.pump(const Duration(milliseconds: 60));
      expect(h.channel.sent.last, isNull);
      final count = h.channel.sent.length;
      await tester.pump(const Duration(seconds: 1));
      expect(
        h.channel.sent,
        hasLength(count),
        reason: 'b still runs, but tracking stays off until the app is back',
      );

      h.tracker.visible = true;
      await tester.pump(const Duration(seconds: 1));
      expect(h.channel.sessionId, 'claude:b');
      h.dispose();
    },
  );

  testWidgets('keeps tracking across a queued prompt but not a stuck queue', (
    tester,
  ) async {
    final h = _Harness();
    await h.setUp([_listed('claude:a', 'running')]);
    h.tracker.visible = false;
    expect(h.channel.sessionId, 'claude:a');

    h.client.state('claude:a', 'idle', queued: 1);
    await tester.pump(const Duration(seconds: 1));
    expect(h.channel.sent.last?['detail'], '準備處理下一則排隊訊息…');
    h.client.state('claude:a', 'running');
    await tester.pump(const Duration(seconds: 1));
    expect(h.channel.sent.last?['detail'], '執行中…');

    h.client.state('claude:a', 'idle', queued: 1);
    await tester.pump(const Duration(seconds: 9));
    expect(h.channel.sent.last, isNotNull);
    await tester.pump(const Duration(seconds: 2));
    expect(h.channel.sent.last, isNull);
    h.dispose();
  });

  testWidgets('shows a dropped connection', (tester) async {
    final h = _Harness();
    await h.setUp([_listed('claude:a', 'running')]);
    h.tracker.visible = false;
    h.client.goOffline();
    await tester.pump(const Duration(seconds: 1));
    expect(h.channel.sent.last, containsPair('phase', 'offline'));
    expect(h.channel.sent.last?['detail'], '連線中斷，重新連線中…');
    h.dispose();
  });

  testWidgets(
    'picks up a conversation opened after it was armed and coalesces updates',
    (tester) async {
      final h = _Harness();
      await h.setUp([_listed('claude:a', 'running')], enabled: false);
      h.tracker.viewing = 'claude:a';
      expect(h.channel.sent, isEmpty, reason: 'disabled');

      await h.tracker.setEnabled(true);
      expect(h.channel.sent.single?['detail'], '執行中…');

      h.open('claude:a');
      await tester.pump(const Duration(milliseconds: 60));
      expect(
        h.channel.sent,
        hasLength(1),
        reason: 'held back for the rest of the second',
      );
      await tester.pump(const Duration(seconds: 1));
      expect(h.channel.sent, hasLength(2));
      expect(h.channel.sent.last?['detail'], 'Run flutter test');
      expect(h.channel.sent.last?['startedAt'], 1700000000000);

      h.update('claude:a', {
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 't1',
        'title': 'mcp__plugin_context7_context7__resolve-library-id',
      });
      await tester.pump(const Duration(seconds: 1));
      expect(
        h.channel.sent.last?['detail'],
        'context7 · resolve-library-id',
        reason: 'MCP tools read as in the app',
      );

      await h.tracker.setEnabled(false);
      expect(h.channel.sent.last, isNull, reason: 'removal is not held back');
      await tester.pump(const Duration(seconds: 1));
      h.dispose();
    },
  );
}
