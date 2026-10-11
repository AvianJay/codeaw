import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/remote_desktop_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _MemoryStore extends HostStore {
  Map<String, dynamic>? preferences;
  final writes = <Map<String, dynamic>>[];
  Future<void> Function(Map<String, dynamic>)? beforeSave;

  @override
  Future<Map<String, dynamic>?> loadDesktopPreferences(HostConfig host) async =>
      preferences;

  @override
  Future<void> saveDesktopPreferences(
    HostConfig host,
    Map<String, dynamic> value,
  ) async {
    await beforeSave?.call(value);
    preferences = Map.of(value);
    writes.add(Map.of(value));
  }
}

class _DesktopHarness {
  _DesktopHarness(this.server);

  final HttpServer server;
  final store = _MemoryStore();
  final requests = <Map<String, dynamic>>[];
  final messages = <Map<String, dynamic>>[];
  final sockets = <WebSocket>[];
  final info = <String, dynamic>{
    'enabled': true,
    'available': true,
    'privilegeModes': ['user', 'system'],
    'smooth': true,
    'hardware': true,
    'monitors': [
      {'id': 'primary', 'primary': true},
      {'id': 'second', 'primary': false},
    ],
  };
  bool dataSaver = false;
  Completer<void>? sessionResponseGate;
  Completer<void>? sessionRequested;
  late final RemoteDesktopController controller;
  int epoch = 0;

  static Future<_DesktopHarness> create() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final harness = _DesktopHarness(server);
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      harness.sockets.add(socket);
      socket.listen((value) {
        final message = jsonDecode(value as String) as Map<String, dynamic>;
        harness.messages.add(message);
        if (message['type'] == 'auth' || message['type'] == 'configure') {
          final options = message['type'] == 'auth'
              ? harness.requests.last
              : message['options'] as Map<String, dynamic>;
          socket.add(
            jsonEncode({
              'type': 'status',
              'state': 'active',
              'epoch': ++harness.epoch,
              'mode': options['mode'],
            }),
          );
        }
      });
    });
    harness.controller = RemoteDesktopController(
      HostConfig(
        name: 'Auto selection test',
        urls: ['ws://127.0.0.1:${server.port}/acp'],
        token: 'test',
        deviceId: 'test',
        deviceName: 'Phone',
      ),
      harness.store,
      dataSaver: () => harness.dataSaver,
      httpClient: MockClient((request) async {
        if (request.method == 'GET') {
          return http.Response(jsonEncode(harness.info), 200);
        }
        if (request.method == 'POST') {
          harness.requests.add(
            jsonDecode(request.body) as Map<String, dynamic>,
          );
          harness.sessionRequested?.complete();
          await harness.sessionResponseGate?.future;
          return http.Response(
            jsonEncode({
              'sessionId': 'session-${harness.requests.length}',
              'socketPath': '/desktop',
              'ticket': 'test',
            }),
            200,
          );
        }
        return http.Response('{}', 200);
      }),
    );
    return harness;
  }

  Future<void> connect() async {
    await controller.connect();
    await waitFor(() => controller.active);
  }

  Future<void> waitFor(bool Function() ready) async {
    if (ready()) return;
    final done = Completer<void>();
    void listener() {
      if (!done.isCompleted && ready()) done.complete();
    }

    controller.addListener(listener);
    try {
      await done.future.timeout(const Duration(seconds: 3));
    } finally {
      controller.removeListener(listener);
    }
  }

  Future<void> close() async {
    await controller.disconnect();
    controller.dispose();
    for (final socket in sockets) {
      await socket.close();
    }
    await server.close(force: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _DesktopHarness harness;
  setUp(() async => harness = await _DesktopHarness.create());
  tearDown(() async => harness.close());

  test(
    'selects hardware smooth and advanced control over old manual choices',
    () async {
      harness.store.preferences = {
        'mode': 'onDemand',
        'fps': 30,
        'privilege': 'user',
        'monitorId': 'second',
      };

      await harness.connect();

      expect(harness.requests.single, {
        'mode': 'smooth',
        'fps': 60,
        'privilege': 'system',
        'monitorId': 'second',
      });
    },
  );

  test(
    'selects software smooth at 30 fps and available user control',
    () async {
      harness.info['hardware'] = false;
      harness.info['privilegeModes'] = ['user'];
      harness.store.preferences = {
        'mode': 'low',
        'fps': 60,
        'privilege': 'system',
        'monitorId': 'removed-monitor',
      };

      await harness.connect();

      expect(harness.requests.single, {
        'mode': 'smooth',
        'fps': 30,
        'privilege': 'user',
        'monitorId': 'primary',
      });
    },
  );

  test('uses balanced when smooth streaming is unavailable', () async {
    harness.info['smooth'] = false;

    await harness.connect();

    expect(harness.requests.single['mode'], 'balanced');
    expect(harness.requests.single['fps'], 30);
  });

  test(
    'data saver takes priority over hardware streaming capabilities',
    () async {
      harness.dataSaver = true;

      await harness.connect();

      expect(harness.requests.single['mode'], 'low');
      expect(harness.requests.single['fps'], 30);
      expect(harness.requests.single['privilege'], 'system');
    },
  );

  test('reconnect reevaluates capabilities and data saver', () async {
    await harness.connect();
    await harness.controller.disconnect();
    harness.info['privilegeModes'] = ['user'];
    harness.dataSaver = true;

    await harness.connect();

    expect(harness.requests.last['mode'], 'low');
    expect(harness.requests.last['fps'], 30);
    expect(harness.requests.last['privilege'], 'user');
  });

  test(
    'monitor changes use automatic options and save only monitor preference',
    () async {
      await harness.connect();
      harness.dataSaver = true;

      await harness.controller.configure(
        monitorId: 'second',
        mode: DesktopMode.onDemand,
        fps: 60,
        privilege: 'user',
      );
      await harness.waitFor(() => harness.controller.active);

      final configuration = harness.messages.singleWhere(
        (message) => message['type'] == 'configure',
      );
      expect(configuration['options'], {
        'mode': 'low',
        'fps': 30,
        'privilege': 'system',
        'monitorId': 'second',
      });
      expect(harness.store.preferences, {'monitorId': 'second'});
      expect(harness.requests, hasLength(1));
    },
  );

  test(
    'server smooth fallback stays active without automatic retry loops',
    () async {
      await harness.connect();
      harness.sockets.single.add(
        jsonEncode({
          'type': 'status',
          'state': 'active',
          'epoch': ++harness.epoch,
          'mode': 'balanced',
        }),
      );
      await harness.waitFor(
        () => harness.controller.actualMode == DesktopMode.balanced,
      );

      expect(harness.controller.active, isTrue);
      expect(harness.controller.mode, DesktopMode.smooth);
      expect(harness.controller.targetFps, 15);
      expect(
        harness.messages.where((message) => message['type'] == 'configure'),
        isEmpty,
      );
      expect(harness.requests, hasLength(1));
    },
  );

  test(
    'manual choices apply in place and reload on the next connection',
    () async {
      await harness.connect();
      final controller = harness.controller;

      await controller.setStreamPreferences(mode: DesktopMode.smooth, fps: 30);
      await harness.waitFor(
        () => controller.active && controller.targetFps == 30,
      );

      expect(harness.requests, hasLength(1));
      expect(harness.messages.skip(1).map((message) => message['type']), [
        'input',
        'configure',
      ]);
      expect((harness.messages[1]['input'] as Map)['kind'], 'release');
      expect(harness.store.preferences, {
        'monitorId': 'primary',
        'preferredMode': 'smooth',
        'preferredFps': 30,
      });
      expect(controller.modeAutomatic, isFalse);
      expect(controller.fpsAutomatic, isFalse);

      final reloaded = await _DesktopHarness.create();
      reloaded.store.preferences = Map.of(harness.store.preferences!);
      try {
        await reloaded.connect();
        expect(reloaded.requests.single['mode'], 'smooth');
        expect(reloaded.requests.single['fps'], 30);
        expect(reloaded.controller.preferredMode, DesktopMode.smooth);
        expect(reloaded.controller.preferredFps, 30);
      } finally {
        await reloaded.close();
      }
    },
  );

  test(
    'manual quality overrides data saver and null restores automatic choice',
    () async {
      harness.dataSaver = true;
      await harness.controller.setStreamPreferences(
        mode: DesktopMode.smooth,
        fps: 60,
      );
      await harness.connect();
      expect(harness.requests.single['mode'], 'smooth');
      expect(harness.controller.targetFps, 60);

      await harness.controller.setStreamPreferences(mode: null, fps: null);
      await harness.waitFor(() => harness.controller.active);

      expect(harness.controller.mode, DesktopMode.low);
      expect(harness.controller.targetFps, 2);
      expect(harness.controller.modeAutomatic, isTrue);
      expect(harness.controller.fpsAutomatic, isTrue);
      expect(harness.store.preferences, {'monitorId': 'primary'});
      expect(harness.requests, hasLength(1));
    },
  );

  test(
    'manual smooth and 60 fps preferences survive capability limits',
    () async {
      harness.info['hardware'] = false;
      await harness.controller.setStreamPreferences(
        mode: DesktopMode.smooth,
        fps: 60,
      );
      await harness.connect();
      expect(harness.controller.targetFps, 30);
      expect(harness.controller.preferredFps, 60);

      await harness.controller.disconnect();
      harness.info['smooth'] = false;
      await harness.connect();
      expect(harness.controller.mode, DesktopMode.balanced);
      expect(harness.controller.targetFps, 15);
      expect(harness.controller.preferredMode, DesktopMode.smooth);
      expect(harness.controller.preferredFps, 60);

      await harness.controller.disconnect();
      harness.info['smooth'] = true;
      harness.info['hardware'] = true;
      await harness.connect();
      expect(harness.controller.mode, DesktopMode.smooth);
      expect(harness.controller.targetFps, 60);
      expect(harness.requests.last['fps'], 60);
    },
  );

  test(
    'fixed-rate modes keep their limits and retain later smooth fps preference',
    () async {
      await harness.connect();
      for (final entry in {
        DesktopMode.balanced: 15,
        DesktopMode.low: 2,
        DesktopMode.onDemand: 1,
      }.entries) {
        await harness.controller.setStreamPreferences(mode: entry.key, fps: 60);
        await harness.waitFor(() => harness.controller.active);
        expect(harness.controller.targetFps, entry.value);
        expect(harness.controller.requestedFps, 30);
        expect(harness.controller.preferredFps, 60);
      }
      await harness.controller.setStreamPreferences(
        mode: DesktopMode.smooth,
        fps: 60,
      );
      await harness.waitFor(() => harness.controller.active);
      expect(harness.controller.targetFps, 60);
    },
  );

  test(
    'unchanged choices and inactive fps changes do not reconfigure',
    () async {
      harness.info['hardware'] = false;
      await harness.connect();
      await harness.controller.setStreamPreferences(mode: null, fps: null);
      expect(harness.store.writes, isEmpty);

      await harness.controller.setStreamPreferences(mode: null, fps: 60);
      expect(harness.controller.preferredFps, 60);
      expect(harness.controller.targetFps, 30);
      expect(harness.messages, hasLength(1));
      expect(harness.controller.active, isTrue);
      expect(harness.store.writes, hasLength(1));

      await harness.controller.setStreamPreferences(mode: null, fps: 60);
      expect(harness.messages, hasLength(1));
      expect(harness.store.writes, hasLength(1));
    },
  );

  test('offline changes persist without opening a desktop session', () async {
    harness.store.preferences = {
      'mode': 'onDemand',
      'fps': 60,
      'privilege': 'system',
      'monitorId': 'second',
    };
    await harness.controller.setStreamPreferences(
      mode: DesktopMode.low,
      fps: 30,
    );
    expect(harness.controller.visible, isFalse);
    expect(harness.controller.active, isFalse);
    expect(harness.requests, isEmpty);
    expect(harness.sockets, isEmpty);
    expect(harness.controller.mode, DesktopMode.low);
    expect(harness.controller.targetFps, 2);
    expect(harness.store.preferences, {
      'monitorId': 'second',
      'preferredMode': 'low',
      'preferredFps': 30,
    });

    await harness.controller.configure(monitorId: 'primary');
    expect(harness.requests, isEmpty);
    expect(harness.store.preferences, {
      'monitorId': 'primary',
      'preferredMode': 'low',
      'preferredFps': 30,
    });
  });

  test(
    'monitor and stream preference writes are serialized without lost choices',
    () async {
      await harness.connect();
      final saveStarted = Completer<void>();
      final saveGate = Completer<void>();
      harness.store.beforeSave = (_) async {
        if (!saveStarted.isCompleted) {
          saveStarted.complete();
          await saveGate.future;
        }
      };
      final streamChange = harness.controller.setStreamPreferences(
        mode: DesktopMode.low,
        fps: 30,
      );
      await saveStarted.future;
      final monitorChange = harness.controller.configure(monitorId: 'second');
      saveGate.complete();
      await Future.wait([streamChange, monitorChange]);
      await harness.waitFor(
        () => harness.controller.active && harness.epoch == 3,
      );

      expect(harness.store.preferences, {
        'monitorId': 'second',
        'preferredMode': 'low',
        'preferredFps': 30,
      });
      final configurations = harness.messages
          .where((message) => message['type'] == 'configure')
          .map((message) => message['options'] as Map);
      expect(configurations.map((options) => options['monitorId']), [
        'primary',
        'second',
      ]);
      expect(
        configurations.every((options) => options['mode'] == 'low'),
        isTrue,
      );
      expect(harness.requests, hasLength(1));
    },
  );

  test(
    'preferences changed during session creation apply after authentication',
    () async {
      harness.sessionRequested = Completer<void>();
      harness.sessionResponseGate = Completer<void>();
      final connection = harness.controller.connect();
      await harness.sessionRequested!.future;
      await harness.controller.setStreamPreferences(
        mode: DesktopMode.low,
        fps: null,
      );
      expect(harness.messages, isEmpty);
      harness.sessionResponseGate!.complete();
      await connection;
      await harness.waitFor(
        () => harness.controller.actualMode == DesktopMode.low,
      );

      expect(harness.messages.map((message) => message['type']), [
        'auth',
        'input',
        'configure',
      ]);
      expect(harness.requests, hasLength(1));
      expect(harness.requests.single['mode'], 'smooth');
      expect(harness.controller.targetFps, 2);
    },
  );

  test(
    'cursor revision tracks fresh cursor messages, not other updates',
    () async {
      await harness.connect();
      final controller = harness.controller;
      final currentEpoch = controller.epoch;
      Future<void> cursor(int epoch, {int generation = 1}) =>
          controller.receive(
            jsonEncode({
              'type': 'cursor',
              'epoch': epoch,
              'x': .3,
              'y': .4,
              'visible': true,
            }),
            generation,
          );

      expect(controller.cursorRevision, 0);
      await cursor(currentEpoch - 1);
      await cursor(currentEpoch, generation: 0);
      expect(controller.cursorRevision, 0);
      expect(controller.cursorX, .5);

      await cursor(currentEpoch);
      expect(controller.cursorRevision, 1);
      expect(controller.cursorX, .3);
      expect(controller.cursorY, .4);
      await cursor(currentEpoch);
      expect(controller.cursorRevision, 2);

      await controller.receive(
        jsonEncode({
          'type': 'status',
          'state': 'active',
          'mode': 'smooth',
          'epoch': currentEpoch + 1,
        }),
        1,
      );
      await cursor(currentEpoch);
      expect(controller.cursorRevision, 2);

      // The stats timer notifies listeners even without a fresh cursor event.
      var notifications = 0;
      void onChanged() => notifications++;
      controller.addListener(onChanged);
      try {
        await harness.waitFor(() => notifications > 0);
        expect(controller.cursorRevision, 2);
      } finally {
        controller.removeListener(onChanged);
      }

      await cursor(currentEpoch + 1);
      expect(controller.cursorRevision, 3);
    },
  );
}
