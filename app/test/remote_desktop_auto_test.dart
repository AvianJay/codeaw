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

  @override
  Future<Map<String, dynamic>?> loadDesktopPreferences(HostConfig host) async =>
      preferences;

  @override
  Future<void> saveDesktopPreferences(
    HostConfig host,
    Map<String, dynamic> value,
  ) async {
    preferences = Map.of(value);
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
      expect(
        harness.messages.where((message) => message['type'] == 'configure'),
        isEmpty,
      );
      expect(harness.requests, hasLength(1));
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
