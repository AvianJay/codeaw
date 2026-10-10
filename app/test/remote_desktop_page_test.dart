import 'dart:io';
import 'dart:ui' as ui;

import 'package:codeaw/app_state.dart';
import 'package:codeaw/ui/remote_desktop/remote_desktop_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'remote_desktop_test.dart' show FakeDesktop, MemoryStore, host;

const preview = bool.fromEnvironment('CODEAW_DESKTOP_PREVIEW');
final boundary = GlobalKey();

class _PreviewBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get disableShadows => false;
}

Future<FakeDesktop> mountDesktop(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  if (preview && File('C:/Windows/Fonts/msjh.ttc').existsSync()) {
    final font = FontLoader('DesktopPreview');
    font.addFont(
      Future.value(
        ByteData.sublistView(
          File('C:/Windows/Fonts/msjh.ttc').readAsBytesSync(),
        ),
      ),
    );
    await tester.runAsync(() => font.load());
    final iconFile = File(
      'D:/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    if (iconFile.existsSync()) {
      final icons = FontLoader('MaterialIcons');
      icons.addFont(
        Future.value(ByteData.sublistView(iconFile.readAsBytesSync())),
      );
      await tester.runAsync(() => icons.load());
    }
  }
  final controller = FakeDesktop()
    ..width = 1920
    ..height = 1080
    ..cursorVisible = true;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(const Color(0xff526e95), BlendMode.src);
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      const Rect.fromLTWH(80, 50, 700, 440),
      const Radius.circular(14),
    ),
    Paint()..color = const Color(0xfff4f6fa),
  );
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      const Rect.fromLTWH(80, 50, 700, 48),
      const Radius.circular(14),
    ),
    Paint()..color = const Color(0xffe0e6ef),
  );
  for (var i = 0; i < 5; i++) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(116, 132 + 52.0 * i, 260 + 24.0 * i, 14),
        const Radius.circular(7),
      ),
      Paint()..color = const Color(0xffcdd7e7),
    );
  }
  final picture = recorder.endRecording();
  controller.image = await picture.toImage(960, 540);
  picture.dispose();
  final state = AppState(MemoryStore(), openSession: (_) {})
    ..host = host
    ..desktop = controller
    ..loaded = true;
  await tester.pumpWidget(
    AppScope(
      state: state,
      child: RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            useMaterial3: true,
            colorSchemeSeed: const Color(0xff355cd4),
            fontFamily: preview ? 'DesktopPreview' : null,
          ),
          home: const RemoteDesktopPage(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    state.desktop = null;
    state.dispose();
  });
  return controller;
}

Future<void> capture(WidgetTester tester, String name) async {
  if (!preview) return;
  await tester.runAsync(() async {
    final render =
        boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await render.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory('build/desktop-preview')
      ..createSync(recursive: true);
    File(
      '${directory.path}/$name.png',
    ).writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  if (preview) _PreviewBinding();
  setUp(
    () => SharedPreferences.setMockInitialValues({
      'desktop.gestureGuideSeen.v1': true,
    }),
  );

  testWidgets(
    'first visit teaches gestures, then leaves only the overflow controls',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await mountDesktop(tester);
      expect(find.text('把手機當作觸控板'), findsOneWidget);
      expect(find.text('兩指點一下'), findsOneWidget);
      expect(find.text('兩指上下左右滑'), findsOneWidget);
      await capture(tester, 'gesture-guide');
      await tester.ensureVisible(find.text('開始操控'));
      await tester.tap(find.text('開始操控'));
      await tester.pumpAndSettle();
      expect(find.byType(DropdownButton), findsNothing);
      expect(find.text('Ctrl+C'), findsNothing);
      expect(find.byTooltip('桌面選項'), findsOneWidget);
      await capture(tester, 'desktop');
      await tester.tap(find.byTooltip('桌面選項'));
      await tester.pumpAndSettle();
      expect(find.text('顯示鍵盤'), findsOneWidget);
      expect(find.text('手勢教學'), findsOneWidget);
      expect(find.text('一般權限'), findsNothing);
      expect(find.text('高流暢'), findsNothing);
      await capture(tester, 'overflow-menu');
      await tester.tap(find.text('手勢教學'));
      await tester.pumpAndSettle();
      expect(find.text('把手機當作觸控板'), findsOneWidget);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          'desktop.gestureGuideSeen.v1',
        ),
        isTrue,
      );
    },
  );

  testWidgets(
    'portrait touchpad uses full touch area and ignores delayed cursor echoes',
    (tester) async {
      final controller = await mountDesktop(tester);
      final imageSize = tester.getSize(find.byType(RawImage));
      final touch = await tester.startGesture(const Offset(80, 700));
      await touch.moveBy(const Offset(20, 20));
      await tester.pump(const Duration(milliseconds: 17));
      var move = controller.inputs.lastWhere(
        (input) => input['kind'] == 'pointer',
      );
      expect((move['x'] as double) - .5, closeTo(20 / imageSize.width, .001));
      expect((move['y'] as double) - .5, closeTo(20 / imageSize.height, .001));
      controller.cursorX = .1;
      controller.cursorY = .1;
      controller.cursorRevision++;
      controller.notifyListeners();
      await tester.pump();
      await touch.moveBy(const Offset(20, 0));
      await tester.pump(const Duration(milliseconds: 17));
      move = controller.inputs.lastWhere((input) => input['kind'] == 'pointer');
      expect(move['x'], closeTo(.5 + 40 / imageSize.width, .001));
      await touch.up();
      await tester.pump(const Duration(seconds: 1));
      controller
          .notifyListeners(); // Stats/UI notifications cannot replay the ignored echo.
      await tester.pump();
      final next = await tester.startGesture(const Offset(80, 700));
      await next.moveBy(const Offset(20, 0));
      await tester.pump(const Duration(milliseconds: 17));
      move = controller.inputs.lastWhere((input) => input['kind'] == 'pointer');
      expect(move['x'], closeTo(.5 + 60 / imageSize.width, .001));
      await next.up();
    },
  );

  testWidgets(
    'two-finger tap right clicks and opening the menu releases a held drag',
    (tester) async {
      final controller = await mountDesktop(tester);
      final first = await tester.startGesture(
        const Offset(100, 650),
        pointer: 1,
      );
      final second = await tester.startGesture(
        const Offset(160, 650),
        pointer: 2,
      );
      await first.up();
      await second.up();
      final clicks = controller.inputs
          .where((input) => input['kind'] == 'button')
          .toList();
      expect(clicks.map((input) => input['button']), ['right', 'right']);
      expect(clicks.map((input) => input['down']), [true, false]);
      controller.inputs.clear();
      final held = await tester.startGesture(
        const Offset(100, 650),
        pointer: 3,
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        controller.inputs
            .where((input) => input['kind'] == 'button')
            .single['down'],
        isTrue,
      );
      await tester.tap(find.byTooltip('桌面選項'));
      await tester.pumpAndSettle();
      expect(
        controller.inputs.any(
          (input) =>
              input['kind'] == 'button' &&
              input['button'] == 'left' &&
              input['down'] == false,
        ),
        isTrue,
      );
      await held.up();
      expect(tester.takeException(), isNull);
    },
  );
}
