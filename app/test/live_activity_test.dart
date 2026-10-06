import 'dart:async';

import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/live_activity.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Client extends BridgeClient {
  _Client(String id)
    : super(
        HostConfig(
          name: 'PC',
          urls: ['ws://pc/acp'],
          token: 'test',
          deviceId: id,
          deviceName: 'test',
        ),
      ) {
    status = ConnStatus.online;
  }
  final calls = <({String method, Map<String, dynamic>? params})>[];
  final reconnects = StreamController<void>.broadcast(sync: true);
  bool apns = false;
  List<Map<String, dynamic>> snapshots = [];
  @override
  Stream<void> get connected => reconnects.stream;
  @override
  Future<dynamic> request(String method, [Map<String, dynamic>? params]) async {
    calls.add((method: method, params: params));
    return switch (method) {
      '_codeaw/live_activity/info' => {
        'enabled': apns,
        'ready': apns,
        'includeDetails': apns,
      },
      '_codeaw/activity/list' => {'activities': snapshots},
      '_codeaw/live_activity/register' => {'registered': true},
      _ => {},
    };
  }

  @override
  void dispose() {
    reconnects.close();
    super.dispose();
  }
}

Map<String, dynamic> work({
  String session = 'codex:one',
  String turn = 'turn',
  String state = 'running',
  String summary = 'npm test',
  String title = 'Fix chat history',
}) => {
  'sessionId': session,
  'agentId': 'codex',
  'title': title,
  'state': state,
  if (state != 'idle') ...{'turnPromptId': turn, 'turnStartedAt': 1000},
  if (state == 'idle')
    'completedTurn': {'promptId': turn, 'startedAt': 1000, 'endedAt': 5000},
  'work': {
    'project': 'Codeaw',
    'phase': state == 'idle' ? 'completed' : 'command',
    'summary': summary,
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'tracks concurrent chats without opening them and serializes completion independently',
    () async {
      final native = <({String method, Map<String, dynamic>? params})>[];
      final controller = LiveActivityController(
        platformSupported: true,
        nativeCall: (method, params) async {
          native.add((method: method, params: params));
          return method == 'status'
              ? {'supported': true, 'authorized': true}
              : {};
        },
      );
      final client = _Client('PC-A');
      await controller.initialize();
      controller.bind(client);
      await controller.refresh();
      controller.accept(work(session: 'codex:other'));
      await controller.settled;
      expect(
        native.where((c) => c.method == 'sync').single.params!['sessionId'],
        'codex:other',
      );
      controller.follow('codex:one');
      controller.accept(work());
      controller.accept(work(state: 'idle'));
      await controller.settled;
      final sync = native.where((c) => c.method == 'sync').toList();
      expect(sync.map((c) => c.params!['state']), [
        'running',
        'running',
        'idle',
      ]);
      expect(sync.last.params!['title'], 'Fix chat history');
      expect(sync.last.params, containsPair('startedAt', 1000));
      expect(sync.last.params, containsPair('endedAt', 5000));
      expect(sync.every((c) => c.params!['hostKey'] == 'PC-A'), isTrue);
      controller.dispose();
      await controller.settled;
      client.dispose();
    },
  );

  test(
    'privacy changes redact current content and disable ends activities',
    () async {
      final native = <({String method, Map<String, dynamic>? params})>[];
      final controller = LiveActivityController(
        platformSupported: true,
        nativeCall: (method, params) async {
          native.add((method: method, params: params));
          return {};
        },
      );
      final client = _Client('PC-A');
      controller.bind(client);
      controller.follow('codex:one');
      controller.accept(work(summary: 'private command'));
      await controller.settled;
      await controller.configure(showDetails: false);
      final sync = native.lastWhere((c) => c.method == 'sync').params!;
      expect(sync['project'], 'Codeaw');
      expect(sync['title'], 'Codeaw');
      expect(sync['summary'], 'AI 正在工作…');
      expect(sync.values, isNot(contains('private command')));
      await controller.configure(enabled: false);
      expect(native.last.method, 'endAll');
      final count = native.length;
      controller.accept(work(summary: 'more'));
      await controller.settled;
      expect(native.length, count);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('codeaw.liveActivity.enabled'), isFalse);
      controller.dispose();
      await controller.settled;
      client.dispose();
    },
  );

  test(
    'restores local activities and re-registers rotated APNs tokens after reconnect',
    () async {
      var token = 'a' * 64;
      final controller = LiveActivityController(
        platformSupported: true,
        nativeCall: (method, params) async => method == 'status'
            ? {
                'authorized': true,
                'activities': [
                  {
                    'hostKey': 'PC-A',
                    'sessionId': 'codex:one',
                    'turnId': 'turn',
                    'activityId': 'activity',
                  },
                ],
                'tokens': [
                  {
                    'hostKey': 'PC-A',
                    'sessionId': 'codex:one',
                    'turnId': 'turn',
                    'activityId': 'activity',
                    'pushToken': token,
                  },
                ],
              }
            : {},
      );
      final client = _Client('PC-A')
        ..apns = true
        ..snapshots = [work()];
      controller.bind(client);
      await controller.refresh();
      await controller.settled;
      var registrations = client.calls.where(
        (c) => c.method == '_codeaw/live_activity/register',
      );
      expect(registrations, isNotEmpty);
      expect(registrations.last.params!['pushToken'], token);
      token = 'b' * 64;
      client.reconnects.add(null);
      await controller.refresh();
      await controller.settled;
      registrations = client.calls.where(
        (c) => c.method == '_codeaw/live_activity/register',
      );
      expect(registrations.last.params!['pushToken'], token);
      await controller.configure(showDetails: false);
      registrations = client.calls.where(
        (c) => c.method == '_codeaw/live_activity/register',
      );
      expect(registrations.last.params!['includeDetails'], isFalse);
      controller.dispose();
      await controller.settled;
      client.dispose();
    },
  );

  test(
    'tracks five distinct running sessions and updates titles without ending the others',
    () async {
      final native = <Map<String, dynamic>>[];
      final controller = LiveActivityController(
        platformSupported: true,
        nativeCall: (method, params) async {
          if (method == 'sync') native.add(params!);
          return {};
        },
      );
      final client = _Client('PC-A');
      controller.bind(client);
      for (var i = 0; i < 5; i++) {
        controller.accept(work(session: 'codex:$i', title: 'Chat $i'));
      }
      await controller.settled;
      expect(native.map((s) => s['sessionId']).toSet().length, 5);
      expect(native.every((s) => s['backgroundUpdates'] == false), isTrue);
      controller.accept(work(session: 'codex:0', title: 'Renamed chat'));
      controller.accept(work(session: 'codex:1', state: 'idle'));
      await controller.settled;
      expect(native[native.length - 2]['title'], 'Renamed chat');
      expect(native.last['sessionId'], 'codex:1');
      expect(native.last['state'], 'idle');
      controller.dispose();
      await controller.settled;
      client.dispose();
    },
  );

  test(
    'switching computer cannot apply queued snapshots from the previous host',
    () async {
      final native = <({String method, Map<String, dynamic>? params})>[];
      final controller = LiveActivityController(
        platformSupported: true,
        nativeCall: (method, params) async {
          native.add((method: method, params: params));
          return {};
        },
      );
      final a = _Client('A'), b = _Client('B');
      controller.bind(a);
      controller.follow('codex:one');
      controller.accept(work(summary: 'A-secret'));
      controller.bind(b);
      controller.follow('codex:two');
      controller.accept(work(session: 'codex:two', summary: 'B-work'));
      await controller.settled;
      expect(
        native
            .where((c) => c.method == 'sync')
            .every((c) => c.params!['hostKey'] == 'B'),
        isTrue,
      );
      expect(
        native.any((c) => c.method == 'endAll' && c.params!['hostKey'] == 'A'),
        isTrue,
      );
      controller.dispose();
      await controller.settled;
      a.dispose();
      b.dispose();
    },
  );
}
