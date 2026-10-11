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

Future<void> pinch(
  WidgetTester tester,
  Offset focal,
  double from,
  double to,
) async {
  final left = await tester.startGesture(
    focal - Offset(from / 2, 0),
    pointer: 10,
  );
  final right = await tester.startGesture(
    focal + Offset(from / 2, 0),
    pointer: 11,
  );
  await left.moveTo(focal - Offset(to / 2, 0));
  await right.moveTo(focal + Offset(to / 2, 0));
  await tester.pump(const Duration(milliseconds: 17));
  await left.up();
  await right.up();
  await tester.pump();
}

Rect desktopViewport(WidgetTester tester) => tester.getRect(
  find
      .ancestor(of: find.byType(RawImage), matching: find.byType(ClipRect))
      .first,
);

Future<void> chooseZoom(WidgetTester tester, String label) async {
  await tester.tap(find.byTooltip('桌面選項'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('畫面大小'));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text(label));
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
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
      expect(find.text('兩指捏合'), findsOneWidget);
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
    'pinch centers the remote cursor and touch motion immediately follows it',
    (tester) async {
      final controller = await mountDesktop(tester);
      controller.inputs.clear();
      final before = tester.getRect(find.byType(RawImage));
      final viewport = desktopViewport(tester);
      final focal = before.center + const Offset(45, 30);
      await pinch(tester, focal, 100, 200);
      final after = tester.getRect(find.byType(RawImage));
      expect(after.width, closeTo(before.width * 2, .01));
      expect(after.center.dx, closeTo(viewport.center.dx, .01));
      expect(after.center.dy, closeTo(viewport.center.dy, .01));
      expect(controller.inputs, isEmpty);

      // The camera tracks the cursor immediately, even far from viewport edges.
      final touch = await tester.startGesture(const Offset(80, 700));
      await touch.moveBy(const Offset(10, 0));
      await tester.pump(const Duration(milliseconds: 17));
      final movedImage = tester.getRect(find.byType(RawImage));
      expect(movedImage.left, closeTo(after.left - 10, .01));
      final move = controller.inputs.lastWhere(
        (input) => input['kind'] == 'pointer',
      );
      expect(move['x'], closeTo(.5 + 10 / after.width, .001));
      expect(
        movedImage.left + (move['x'] as double) * movedImage.width,
        closeTo(viewport.center.dx, .01),
      );
      await touch.up();

      controller.inputs.clear();
      await pinch(tester, focal, 200, 100);
      expect(
        tester.getSize(find.byType(RawImage)).width,
        closeTo(before.width, .01),
      );
      expect(controller.inputs, isEmpty);
    },
  );

  testWidgets(
    'pinch reaches eight times fit cumulatively and respects both zoom limits',
    (tester) async {
      final controller = await mountDesktop(tester);
      controller.inputs.clear();
      final before = tester.getRect(find.byType(RawImage));
      await pinch(tester, before.center, 30, 300);
      expect(
        tester.getSize(find.byType(RawImage)).width,
        closeTo(before.width * 8, .01),
      );
      await pinch(tester, before.center, 300, 20);
      expect(
        tester.getSize(find.byType(RawImage)).width,
        closeTo(before.width, .01),
      );
      for (final zoom in [2, 4, 8, 8]) {
        await pinch(tester, before.center, 100, 200);
        expect(
          tester.getSize(find.byType(RawImage)).width,
          closeTo(before.width * zoom, .01),
        );
      }
      await pinch(tester, before.center, 300, 20);
      expect(
        tester.getSize(find.byType(RawImage)).width,
        closeTo(before.width, .01),
      );

      final left = await tester.startGesture(
        before.center - const Offset(50, 0),
        pointer: 10,
      );
      final right = await tester.startGesture(
        before.center + const Offset(50, 0),
        pointer: 11,
      );
      await left.moveBy(const Offset(-50, 0));
      await right.moveBy(const Offset(50, 0));
      await tester.pump(const Duration(milliseconds: 17));
      await left.up();
      await right.moveBy(const Offset(30, 30));
      await right.up();
      await tester.pump();
      expect(
        tester.getSize(find.byType(RawImage)).width,
        closeTo(before.width * 2, .01),
      );
      expect(controller.inputs, isEmpty);

      await chooseZoom(tester, '符合視窗');
      expect(tester.getRect(find.byType(RawImage)), before);
    },
  );

  testWidgets('zoom menu offers four and eight times fit and resets to fit', (
    tester,
  ) async {
    await mountDesktop(tester);
    final before = tester.getRect(find.byType(RawImage));
    final viewport = desktopViewport(tester);
    await chooseZoom(tester, '400%');
    var image = tester.getRect(find.byType(RawImage));
    expect(image.width, closeTo(before.width * 4, .01));
    expect(image.center, viewport.center);
    await chooseZoom(tester, '800%');
    image = tester.getRect(find.byType(RawImage));
    expect(image.width, closeTo(before.width * 8, .01));
    expect(image.center, viewport.center);
    await chooseZoom(tester, '符合視窗');
    expect(tester.getRect(find.byType(RawImage)), before);
  });

  testWidgets(
    'remote cursor stays centered until camera reaches desktop edges',
    (tester) async {
      final controller = await mountDesktop(tester);
      await chooseZoom(tester, '800%');
      await tester.pump(const Duration(seconds: 1));
      final viewport = desktopViewport(tester);
      controller.inputs.clear();
      for (final cursor in [const Offset(.35, .6), const Offset(.6, .4)]) {
        controller.cursorX = cursor.dx;
        controller.cursorY = cursor.dy;
        controller.cursorRevision++;
        controller.notifyListeners();
        await tester.pump();
        final image = tester.getRect(find.byType(RawImage));
        final projectedCursor =
            image.topLeft +
            Offset(cursor.dx * image.width, cursor.dy * image.height);
        expect(projectedCursor.dx, closeTo(viewport.center.dx, .01));
        expect(projectedCursor.dy, closeTo(viewport.center.dy, .01));
      }
      for (final cursor in [
        const Offset(.001, .001),
        const Offset(.999, .999),
      ]) {
        controller.cursorX = cursor.dx;
        controller.cursorY = cursor.dy;
        controller.cursorRevision++;
        controller.notifyListeners();
        await tester.pump();
        final image = tester.getRect(find.byType(RawImage));
        if (cursor.dx < .5) {
          expect(image.left, closeTo(viewport.left, .01));
          expect(image.top, closeTo(viewport.top, .01));
        } else {
          expect(image.right, closeTo(viewport.right, .01));
          expect(image.bottom, closeTo(viewport.bottom, .01));
        }
        expect(image.left, lessThanOrEqualTo(viewport.left));
        expect(image.top, lessThanOrEqualTo(viewport.top));
        expect(image.right, greaterThanOrEqualTo(viewport.right));
        expect(image.bottom, greaterThanOrEqualTo(viewport.bottom));
      }
      expect(controller.inputs, isEmpty);
    },
  );

  testWidgets(
    'zoomed mouse moves relatively and stationary events cannot move the camera',
    (tester) async {
      final controller = await mountDesktop(tester);
      await chooseZoom(tester, '800%');
      final viewport = desktopViewport(tester);
      final imageSize = tester.getSize(find.byType(RawImage));
      controller.inputs.clear();
      final mouse = TestPointer(90, ui.PointerDeviceKind.mouse);
      final entered = viewport.center + const Offset(90, 100);
      await tester.sendEventToBinding(mouse.addPointer(location: entered));
      await tester.sendEventToBinding(mouse.hover(entered));
      await tester.pump(const Duration(milliseconds: 17));
      expect(controller.inputs.last['x'], .5);
      expect(controller.inputs.last['y'], .5);

      final moved = entered + const Offset(10, 0);
      await tester.sendEventToBinding(mouse.hover(moved));
      await tester.pump(const Duration(milliseconds: 17));
      final expectedX = .5 + 10 / imageSize.width;
      expect(controller.inputs.last['x'], closeTo(expectedX, .000001));
      final followed = tester.getRect(find.byType(RawImage));
      expect(
        followed.left + expectedX * followed.width,
        closeTo(viewport.center.dx, .01),
      );
      controller.inputs.clear();

      for (var i = 0; i < 3; i++) {
        await tester.sendEventToBinding(mouse.hover(moved));
        await tester.pump(const Duration(milliseconds: 17));
      }
      await tester.sendEventToBinding(mouse.down(moved));
      await tester.pump();
      await tester.sendEventToBinding(mouse.up());
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 10)));
      await tester.pump(const Duration(milliseconds: 17));
      expect(
        controller.inputs.where((input) => input['kind'] == 'button'),
        hasLength(2),
      );
      expect(
        controller.inputs.where((input) => input['kind'] == 'wheel'),
        hasLength(1),
      );
      for (final input in controller.inputs) {
        expect(input['x'], closeTo(expectedX, .000001));
        expect(input['y'], .5);
      }
      expect(tester.getRect(find.byType(RawImage)), followed);
      await tester.sendEventToBinding(mouse.removePointer());
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
