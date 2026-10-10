import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:codeaw/app_state.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/remote_desktop_controller.dart';
import 'package:codeaw/ui/remote_desktop/remote_desktop_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

final host = HostConfig(
  name: 'Test PC',
  urls: ['ws://localhost:7860/acp'],
  token: 'test',
  deviceId: 'test',
  deviceName: 'Phone',
);

class MemoryStore extends HostStore {
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

Future<Uint8List> tile(Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(color, BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(2, 2);
  picture.dispose();
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return bytes!.buffer.asUint8List();
}

Uint8List packet({
  required int seq,
  required List<Uint8List> tiles,
  bool full = true,
  int epoch = 1,
  int? invalidLength,
}) {
  final metadata = jsonEncode({
    'type': 'frame',
    'epoch': epoch,
    'seq': seq,
    'width': 4,
    'height': 2,
    'full': full,
    'tiles': [
      for (var i = 0; i < tiles.length; i++)
        {
          'x': full ? i * 2 : 2,
          'y': 0,
          'width': 2,
          'height': 2,
          'offset': tiles.take(i).fold(0, (n, data) => n + data.length),
          'length': invalidLength ?? tiles[i].length,
        },
    ],
  });
  final header = utf8.encode(metadata),
      result = Uint8List(
        4 + header.length + tiles.fold(0, (n, data) => n + data.length),
      );
  ByteData.sublistView(result).setUint32(0, header.length, Endian.little);
  result.setRange(4, 4 + header.length, header);
  var offset = 4 + header.length;
  for (final data in tiles) {
    result.setRange(offset, offset + data.length, data);
    offset += data.length;
  }
  return result;
}

class FakeDesktop extends RemoteDesktopController {
  FakeDesktop() : super(host, MemoryStore(), dataSaver: () => false);
  final inputs = <Map<String, dynamic>>[];
  @override
  bool get canInput => active;
  @override
  Future<void> connect() async {
    visible = true;
    active = true;
    loading = false;
    state = 'active';
    notifyListeners();
  }

  @override
  Future<void> disconnect() async {
    visible = false;
    active = false;
  }

  @override
  void input(Map<String, dynamic> value) {
    inputs.add(value);
  }

  @override
  Future<void> configure({
    DesktopMode? mode,
    String? monitorId,
    int? fps,
    String? privilege,
  }) async {
    this.mode = mode ?? this.mode;
    this.monitorId = monitorId ?? this.monitorId;
    this.privilege = privilege ?? this.privilege;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => SharedPreferences.setMockInitialValues({
      'desktop.gestureGuideSeen.v1': true,
    }),
  );
  test(
    'defaults to low data and replaces old manual quality preferences',
    () async {
      final store = MemoryStore();
      final c = RemoteDesktopController(
        host,
        store,
        dataSaver: () => true,
        httpClient: MockClient(
          (_) async => http.Response('{"enabled":false}', 200),
        ),
      );
      await c.connect();
      expect(c.mode, DesktopMode.low);
      c.dispose();
      store.preferences = {
        'mode': 'onDemand',
        'privilege': 'system',
        'fps': 60,
      };
      final next = RemoteDesktopController(
        host,
        store,
        dataSaver: () => false,
        httpClient: MockClient(
          (_) async => http.Response('{"enabled":false}', 200),
        ),
      );
      await next.connect();
      expect(next.mode, DesktopMode.balanced);
      expect(next.requestedFps, 30);
      next.dispose();
    },
  );
  test('composes delta tiles and ignores old screen epochs', () async {
    final c = RemoteDesktopController(
      host,
      MemoryStore(),
      dataSaver: () => false,
    );
    await c.receive(
      '{"type":"status","epoch":1,"mode":"balanced","state":"connecting"}',
      0,
    );
    final red = await tile(const Color(0xffff0000)),
        blue = await tile(const Color(0xff0000ff)),
        green = await tile(Colors.green);
    await c.receive(packet(seq: 1, tiles: [red, blue]), 0);
    var pixels = (await c.image!.toByteData())!.buffer.asUint8List();
    expect(pixels.take(3), [255, 0, 0]);
    expect(pixels.skip(8).take(3), [0, 0, 255]);
    await c.receive(packet(seq: 2, tiles: [green], full: false), 0);
    pixels = (await c.image!.toByteData())!.buffer.asUint8List();
    expect(pixels.take(3), [255, 0, 0]);
    expect(pixels.skip(8).take(3), [76, 175, 80]);
    await c.receive(packet(seq: 3, tiles: [red], epoch: 0), 0);
    expect(
      (await c.image!.toByteData())!.buffer.asUint8List().skip(8).take(3),
      [76, 175, 80],
    );
    await c.disconnect();
    expect(c.image, isNull);
    await c.receive(packet(seq: 1, tiles: [red, blue]), 0);
    expect(c.image, isNull);
    c.dispose();
  });
  test('rejects broken tile lengths and unacknowledged delta bases', () async {
    final c = RemoteDesktopController(
      host,
      MemoryStore(),
      dataSaver: () => false,
    );
    await c.receive(
      '{"type":"status","epoch":1,"mode":"balanced","state":"connecting"}',
      0,
    );
    final red = await tile(Colors.red);
    await expectLater(
      c.receive(packet(seq: 1, tiles: [red], invalidLength: 100000), 0),
      throwsFormatException,
    );
    await expectLater(
      c.receive(packet(seq: 1, tiles: [red], full: false), 0),
      throwsFormatException,
    );
    c.dispose();
  });
  testWidgets(
    'phone controls remain available offline and mouse coordinates follow the fitted image',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = FakeDesktop()
        ..width = 1280
        ..height = 720;
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(Colors.blueGrey, BlendMode.src);
      final picture = recorder.endRecording();
      c.image = await picture.toImage(16, 16);
      picture.dispose();
      final state = AppState(MemoryStore(), openSession: (_) {})
        ..host = host
        ..desktop = c
        ..loaded = true;
      await tester.pumpWidget(
        AppScope(
          state: state,
          child: const MaterialApp(home: RemoteDesktopPage()),
        ),
      );
      await tester.pump();
      expect(find.text('遠端桌面'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final mouse = await tester.createGesture(
        kind: ui.PointerDeviceKind.mouse,
      );
      await mouse.down(tester.getCenter(find.byType(RawImage)));
      await mouse.up();
      await tester.pump();
      final button = c.inputs.firstWhere((input) => input['kind'] == 'button');
      expect(button['x'], closeTo(.5, .01));
      expect(button['y'], closeTo(.5, .01));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.tab);
      expect(
        c.inputs.any((input) => input['kind'] == 'key' && input['code'] == 9),
        isTrue,
      );
      expect(find.byType(DropdownButton<DesktopMode>), findsNothing);
      expect(find.byTooltip('觸控板／直接觸控'), findsNothing);
      await tester.tap(find.byTooltip('桌面選項'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('顯示鍵盤'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '中文😀');
      await tester.pump();
      expect(
        c.inputs.any(
          (input) => input['kind'] == 'text' && input['text'] == '中文😀',
        ),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
      c.image?.dispose();
      c.image = null;
      c.dispose();
      state.desktop = null;
      state.dispose();
    },
  );
}
