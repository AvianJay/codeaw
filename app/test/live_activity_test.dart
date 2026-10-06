import 'dart:async';

import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/live_activity.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:codeaw/ui/settings/live_activity_settings.dart';

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
  Completer<Map<String, dynamic>>? pendingActivities;
  @override
  Stream<void> get connected => reconnects.stream;
  @override
  Future<dynamic> request(String method, [Map<String, dynamic>? params]) async {
    calls.add((method: method, params: params));
    if (method == '_codeaw/activity/list' && pendingActivities != null) {
      return pendingActivities!.future;
    }
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
          return method == 'status'
              ? {'supported': true, 'authorized': true}
              : {};
        },
      );
      final client = _Client('PC-A')
        ..snapshots = [work(summary: 'private command')];
      await controller.initialize();
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
                'supported': true,
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
      await controller.initialize();
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
          return method == 'status'
              ? {'supported': true, 'authorized': true}
              : {};
        },
      );
      final client = _Client('PC-A');
      await controller.initialize();
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
          return method == 'status'
              ? {'supported': true, 'authorized': true}
              : {};
        },
      );
      final a = _Client('A'), b = _Client('B');
      await controller.initialize();
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

  testWidgets(
    'opt-in location follows concurrent work and stops when disabled or unbound',
    (tester) async {
      final native = _LocationNative();
      final controller = LiveActivityController(
        platformSupported: true,
        nativeCall: native.call,
      );
      final client = _Client('A');
      await controller.initialize();
      controller.bind(client);
      await controller.refresh();
      client.snapshots = [work(), work(session: 'codex:two')];
      await controller.refresh();
      await controller.settled;
      expect(controller.locationEnabled, isFalse);
      expect(native.permissionRequests, 0);
      expect(controller.locationActive, isFalse);

      await controller.configure(locationEnabled: true);
      expect(native.permissionRequests, 1);
      expect(controller.locationActive, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('codeaw.liveActivity.location'), isTrue);
      controller.foreground = false;
      final requests = client.calls.length;
      await tester.pump(const Duration(seconds: 60));
      await controller.settled;
      expect(client.calls.length, greaterThan(requests));
      expect(native.sync.last['locationUpdates'], isTrue);
      expect(native.sync.last['backgroundUpdates'], isFalse);

      client.snapshots = [work(state: 'idle'), work(session: 'codex:two')];
      await controller.refresh();
      await controller.settled;
      expect(controller.locationActive, isTrue);
      client.snapshots = [
        work(state: 'idle'),
        work(session: 'codex:two', state: 'idle'),
      ];
      await controller.refresh();
      await controller.settled;
      expect(controller.locationActive, isFalse);
      expect(native.targets.last['running'], isFalse);
      expect(native.permissionRequests, 1);

      controller.foreground = true;
      client.snapshots = [work()];
      await controller.refresh();
      await controller.settled;
      expect(controller.locationActive, isTrue);
      await controller.configure(locationEnabled: false);
      expect(controller.locationActive, isFalse);
      await controller.configure(locationEnabled: true);
      expect(controller.locationActive, isTrue);
      await controller.configure(enabled: false);
      expect(controller.locationActive, isFalse);
      await controller.configure(enabled: true);
      expect(controller.locationActive, isTrue);
      final b = _Client('B');
      controller.bind(b);
      await controller.refresh();
      await controller.settled;
      expect(native.active, isFalse);
      expect(controller.locationActive, isFalse);
      controller.dispose();
      await controller.settled;
      client.dispose();
      b.dispose();
    },
  );

  testWidgets(
    'denied location cannot poll in the background and explains how to recover',
    (tester) async {
      final native = _LocationNative()..authorization = 'denied';
      final controller = LiveActivityController(
        platformSupported: true,
        nativeCall: native.call,
      );
      final client = _Client('A');
      await controller.initialize();
      controller.bind(client);
      await controller.refresh();
      client.snapshots = [work()];
      await controller.refresh();
      await controller.configure(locationEnabled: true);
      expect(controller.locationActive, isFalse);
      controller.foreground = false;
      final requests = client.calls.length;
      await tester.pump(const Duration(seconds: 60));
      expect(client.calls.length, requests);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: LiveActivitySettings(controller: controller),
            ),
          ),
        ),
      );
      expect(find.textContaining('定位權限未允許'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      native.authorization = 'whenInUse';
      controller.foreground = true;
      await controller.refresh();
      await controller.settled;
      expect(controller.locationActive, isTrue);
      expect(native.permissionRequests, 1);
      controller.dispose();
      await controller.settled;
      client.dispose();
    },
  );

  test('cached activity changes retain the actual bridge sync time', () async {
    final native = _LocationNative();
    final controller = LiveActivityController(
      platformSupported: true,
      nativeCall: native.call,
    );
    final client = _Client('A');
    await controller.initialize();
    controller.bind(client);
    await controller.refresh();
    controller.accept(work());
    await controller.settled;
    final time = native.sync.last['updatedAt'];
    client.status = ConnStatus.offline;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await controller.configure(showDetails: false);
    expect(native.sync.last['updatedAt'], time);
    expect(native.sync.last['summary'], 'AI 正在工作…');
    controller.dispose();
    await controller.settled;
    client.dispose();
  });

  test(
    'an old activity list cannot restart location after a streamed completion',
    () async {
      final native = _LocationNative();
      final controller = LiveActivityController(
        platformSupported: true,
        nativeCall: native.call,
      );
      final client = _Client('A');
      await controller.initialize();
      controller.bind(client);
      await controller.refresh();
      client.snapshots = [work()];
      await controller.refresh();
      await controller.configure(locationEnabled: true);
      final pending = client.pendingActivities =
          Completer<Map<String, dynamic>>();
      final count = client.calls
          .where((c) => c.method == '_codeaw/activity/list')
          .length;
      final refresh = controller.refresh();
      while (client.calls
              .where((c) => c.method == '_codeaw/activity/list')
              .length ==
          count) {
        await Future<void>.delayed(Duration.zero);
      }
      controller.accept(work(state: 'idle'));
      await controller.settled;
      expect(native.active, isFalse);
      pending.complete({
        'activities': [work()],
      });
      await refresh;
      await controller.settled;
      expect(native.active, isFalse);
      expect(native.sync.last['state'], 'idle');
      controller.dispose();
      await controller.settled;
      client.dispose();
    },
  );

  testWidgets(
    'native initialization times out without losing activity support',
    (tester) async {
      final response = Completer<dynamic>();
      final controller = LiveActivityController(
        platformSupported: true,
        nativeCall: (method, params) => response.future,
      );
      final operation = controller.initialize();
      await tester.pump();
      await tester.pump(const Duration(seconds: 6));
      await operation;
      expect(controller.supported, isTrue);
      expect(controller.error, isNotNull);
      controller.dispose();
    },
  );
}

class _LocationNative {
  bool active = false;
  String authorization = 'whenInUse';
  int permissionRequests = 0;
  final targets = <Map<String, dynamic>>[];
  final sync = <Map<String, dynamic>>[];
  Map<String, dynamic> get status => {
    'supported': true,
    'active': active,
    'servicesEnabled': true,
    'authorization': authorization,
  };
  Future<dynamic> call(String method, Map<String, dynamic>? params) async {
    if (method == 'status') {
      return {'supported': true, 'authorized': true, 'location': status};
    }
    if (method == 'backgroundLocation') {
      targets.add(params!);
      if (params['requestPermission'] == true) permissionRequests++;
      active =
          params['enabled'] == true &&
          params['running'] == true &&
          authorization == 'whenInUse';
      return status;
    }
    if (method == 'sync') sync.add(params!);
    return {};
  }
}
