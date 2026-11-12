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
  final preferenceChanges = <Map<String, dynamic>>[];
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

  /// Remote copy hand-offs, recorded in order with the keys that follow.
  @override
  Future<void> pushClipboard() async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    if (clipboardSync) inputs.add({'kind': 'clipboard'});
  }

  @override
  Future<void> setStreamPreferences({
    required DesktopMode? mode,
    required int? fps,
  }) async {
    preferenceChanges.add({'mode': mode, 'fps': fps});
    await super.setStreamPreferences(mode: mode, fps: fps);
    actualMode = this.mode;
    notifyListeners();
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
      // The on-screen keyboard's delete keys reach the PC even though nothing
      // typed is left in the field: each press is one key down and one key up.
      List<Object?> keys() => [
        for (final input in c.inputs)
          if (input['kind'] == 'key') '${input['code']}${input['down'] == true ? '↓' : '↑'}',
      ];
      c.inputs.clear();
      final field = tester.widget<TextField>(find.byType(TextField)).controller!;
      final idle = field.value;
      expect(idle.text.length, 2);
      expect(idle.selection.baseOffset, 1);
      for (var press = 0; press < 3; press++) {
        // What the platform reports for Backspace: the character before the cursor is gone.
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: idle.text.substring(1),
            selection: const TextSelection.collapsed(offset: 0),
          ),
        );
        await tester.pump();
        expect(field.value, idle);
      }
      expect(keys(), ['8↓', '8↑', '8↓', '8↑', '8↓', '8↑']);
      c.inputs.clear();
      // Forward delete removes the character after the cursor.
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: idle.text.substring(0, 1),
          selection: const TextSelection.collapsed(offset: 1),
        ),
      );
      await tester.pump();
      expect(keys(), ['46↓', '46↑']);
      expect(field.value, idle);
      c.inputs.clear();
      // Typing and moving the cursor never press a delete key.
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: '${idle.text[0]}a${idle.text[1]}',
          selection: const TextSelection.collapsed(offset: 2),
        ),
      );
      tester.testTextInput.updateEditingValue(
        idle.copyWith(selection: const TextSelection.collapsed(offset: 0)),
      );
      await tester.pump();
      expect(c.inputs, [
        {'kind': 'text', 'text': 'a'},
      ]);
      expect(field.value, idle);
      // A composition in progress is left alone until it is committed.
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: '${idle.text[0]}ㄋ${idle.text[1]}',
          selection: const TextSelection.collapsed(offset: 2),
          composing: const TextRange(start: 1, end: 2),
        ),
      );
      await tester.pump();
      expect(c.inputs.length, 1);
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: '${idle.text[0]}你${idle.text[1]}',
          selection: const TextSelection.collapsed(offset: 2),
        ),
      );
      await tester.pump();
      expect(c.inputs.last, {'kind': 'text', 'text': '你'});
      expect(find.text('Del'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      c.image?.dispose();
      c.image = null;
      c.dispose();
      state.desktop = null;
      state.dispose();
    },
  );

  testWidgets(
    'remote copy is a switch in the menu and a paste carries the phone clipboard first',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = FakeDesktop()
        ..width = 1280
        ..height = 720
        ..clipboardAvailable = true;
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
      Future<CheckedPopupMenuItem<String>> openMenu() async {
        await tester.tap(find.byTooltip('桌面選項'));
        await tester.pumpAndSettle();
        return tester.widget<CheckedPopupMenuItem<String>>(
          find.widgetWithText(CheckedPopupMenuItem<String>, '遠端複製'),
        );
      }

      expect((await openMenu()).checked, isFalse);
      await tester.tap(find.text('遠端複製'));
      await tester.pumpAndSettle();
      expect(c.clipboardSync, isTrue);
      expect(find.textContaining('遠端複製已開啟'), findsOneWidget);
      expect((await openMenu()).checked, isTrue);
      await tester.tap(find.text('顯示鍵盤'));
      await tester.pumpAndSettle();

      // The on-screen paste key: clipboard first, then Ctrl+V.
      c.inputs.clear();
      await tester.tap(find.text('Ctrl+V'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(c.inputs.first, {'kind': 'clipboard'});
      expect(c.inputs.skip(1).map((i) => '${i['code']}${i['down']}'), [
        '17true',
        '86true',
        '86false',
        '17false',
      ]);
      // Other keys do not read the clipboard.
      c.inputs.clear();
      await tester.tap(find.text('Ctrl+C'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(c.inputs.any((i) => i['kind'] == 'clipboard'), isFalse);

      // Text the PC copied is announced once.
      c
        ..clipboardMessage = '已複製電腦上的文字'
        ..clipboardRevision = c.clipboardRevision + 1
        ..notifyListeners();
      // The earlier toast leaves first.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('已複製電腦上的文字'), findsOneWidget);

      // Switching off, and a bridge too old to share.
      await openMenu();
      await tester.tap(find.text('遠端複製'));
      await tester.pumpAndSettle();
      expect(c.clipboardSync, isFalse);
      c.clipboardAvailable = false;
      await openMenu();
      await tester.tap(find.text('遠端複製'));
      await tester.pumpAndSettle();
      expect(c.clipboardSync, isFalse);
      expect(find.text('請更新電腦端 bridge 以使用遠端複製'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      state.desktop = null;
      state.dispose();
    },
  );
}
