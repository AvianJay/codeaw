import 'dart:ui';

import 'package:codeaw/ui/remote_desktop/desktop_trackpad_gestures.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<Map<String, dynamic>> inputs;
  late List<Offset> cursors;
  late DesktopTrackpadGestures gestures;

  setUp(() {
    inputs = [];
    cursors = [];
    gestures = DesktopTrackpadGestures(
      send: inputs.add,
      onCursorChanged: cursors.add,
    )..setViewport(const Size(400, 800));
  });

  tearDown(() => gestures.dispose());

  testWidgets('relative movement uses fitted pixels and coalesces updates', (
    tester,
  ) async {
    gestures.pointerDown(1, const Offset(30, 100));
    gestures.pointerMove(1, const Offset(50, 140));
    gestures.pointerMove(1, const Offset(70, 180));
    expect(gestures.cursor.dx, closeTo(.6, .00001));
    expect(gestures.cursor.dy, closeTo(.6, .00001));
    expect(inputs, isEmpty);
    await tester.pump(const Duration(milliseconds: 16));
    expect(inputs, hasLength(1));
    expect(inputs.single['kind'], 'pointer');
    expect(inputs.single['x'], closeTo(.6, .00001));
    gestures.pointerUp(1);
    expect(inputs.where((input) => input['kind'] == 'button'), isEmpty);
    gestures.dispose();
  });

  testWidgets('portrait letterboxing preserves physical diagonal direction', (
    tester,
  ) async {
    // A landscape desktop fits a 400 x 800 portrait viewport at 400 x 225.
    // Its touchpad still accepts input in the large letterboxed areas.
    gestures.setViewport(const Size(400, 225));
    final before = gestures.cursor;
    gestures.pointerDown(1, const Offset(40, 650));
    gestures.pointerMove(1, const Offset(60, 670));
    final delta = gestures.cursor - before;
    expect(delta.dx * 400, closeTo(20, .00001));
    expect(delta.dy * 225, closeTo(20, .00001));
    gestures.pointerUp(1);
    gestures.dispose();
  });

  testWidgets(
    'mouse to touch adopts the latest local cursor despite echo grace',
    (tester) async {
      gestures.pointerDown(1, const Offset(100, 100));
      gestures.pointerMove(1, const Offset(140, 180));
      gestures.pointerUp(1);
      // A physical mouse then moves elsewhere before its remote echo arrives.
      gestures.adoptLocalCursor(const Offset(.75, .25));
      gestures.syncRemoteCursor(const Offset(.6, .6));
      expect(gestures.cursor, const Offset(.75, .25));
      gestures.pointerDown(2, const Offset(100, 100));
      expect(gestures.hasContacts, isTrue);
      gestures.pointerMove(2, const Offset(120, 140));
      expect(gestures.cursor.dx, closeTo(.8, .00001));
      expect(gestures.cursor.dy, closeTo(.3, .00001));
      gestures.pointerUp(2);
      expect(gestures.hasContacts, isFalse);
      gestures.dispose();
    },
  );

  testWidgets('tap clicks at the predicted cursor and leaves no pending move', (
    tester,
  ) async {
    gestures.syncRemoteCursor(const Offset(.2, .3));
    gestures.pointerDown(1, const Offset(200, 300));
    gestures.pointerMove(1, const Offset(202, 302));
    gestures.pointerUp(1);
    expect(inputs.map((input) => input['kind']), [
      'pointer',
      'button',
      'button',
    ]);
    expect(inputs[1]['button'], 'left');
    expect(inputs[1]['down'], isTrue);
    expect(inputs[2]['down'], isFalse);
    expect(inputs[2]['x'], closeTo(.205, .00001));
    await tester.pump(const Duration(milliseconds: 500));
    expect(inputs, hasLength(3));
    gestures.dispose();
  });

  testWidgets('two-finger tap sends one right click after sequential lift', (
    tester,
  ) async {
    gestures.pointerDown(1, const Offset(100, 100));
    gestures.pointerDown(2, const Offset(140, 100));
    gestures.pointerUp(1);
    expect(gestures.hasContacts, isTrue);
    gestures.pointerMove(2, const Offset(142, 102));
    expect(inputs, isEmpty);
    gestures.pointerUp(2);
    expect(gestures.hasContacts, isFalse);
    expect(inputs.map((input) => input['button']), ['right', 'right']);
    expect(inputs.map((input) => input['down']), [true, false]);
    expect(gestures.cursor, const Offset(.5, .5));
    await tester.pump(const Duration(seconds: 1));
    expect(inputs, hasLength(2));
    gestures.dispose();
  });

  testWidgets('moving the final finger after a pair cannot create a click', (
    tester,
  ) async {
    gestures.pointerDown(1, const Offset(100, 100));
    gestures.pointerDown(2, const Offset(140, 100));
    gestures.pointerUp(1);
    gestures.pointerMove(2, const Offset(200, 160));
    gestures.pointerUp(2);
    expect(inputs, isEmpty);
    expect(cursors, isEmpty);
    gestures.dispose();
  });

  testWidgets('two-finger centroid scrolls naturally in both axes', (
    tester,
  ) async {
    gestures.pointerDown(1, const Offset(100, 100));
    gestures.pointerDown(2, const Offset(140, 100));
    gestures.pointerMove(1, const Offset(120, 130));
    gestures.pointerMove(2, const Offset(160, 130));
    await tester.pump(const Duration(milliseconds: 16));
    expect(inputs, [
      {'kind': 'wheel', 'delta': 90, 'deltaX': -60, 'x': .5, 'y': .5},
    ]);
    gestures.pointerMove(1, const Offset(100, 100));
    gestures.pointerMove(2, const Offset(140, 100));
    gestures.pointerUp(2);
    gestures.pointerMove(1, const Offset(0, 0));
    gestures.pointerUp(1);
    expect(inputs.last, {
      'kind': 'wheel',
      'delta': -90,
      'deltaX': 60,
      'x': .5,
      'y': .5,
    });
    expect(inputs, hasLength(2));
    expect(cursors, isEmpty);
    gestures.dispose();
  });

  testWidgets('slow subpixel scroll accumulates across input frames', (
    tester,
  ) async {
    gestures.pointerDown(1, const Offset(100, 100));
    gestures.pointerDown(2, const Offset(140, 100));
    gestures.pointerMove(1, const Offset(110, 110));
    gestures.pointerMove(2, const Offset(150, 110));
    await tester.pump(const Duration(milliseconds: 16));
    inputs.clear();
    for (var step = 1; step <= 20; step++) {
      final distance = step * .125;
      gestures.pointerMove(1, Offset(110 + distance, 110 + distance));
      gestures.pointerMove(2, Offset(150 + distance, 110 + distance));
      await tester.pump(const Duration(milliseconds: 16));
    }
    // Each frame adds only 0.375 wheel units. Twenty frames accumulate 7.5;
    // seven whole units are emitted, with no reversal on the final flush.
    gestures.pointerUp(1);
    gestures.pointerUp(2);
    expect(inputs.every((input) => input['kind'] == 'wheel'), isTrue);
    expect(
      inputs.fold<int>(0, (sum, input) => sum + (input['delta'] as int)),
      7,
    );
    expect(
      inputs.fold<int>(0, (sum, input) => sum + (input['deltaX'] as int)),
      -7,
    );
    expect(inputs.every((input) => (input['delta'] as int) > 0), isTrue);
    expect(inputs.every((input) => (input['deltaX'] as int) < 0), isTrue);
    gestures.dispose();
  });

  testWidgets('fractional scroll cannot leak into the next gesture', (
    tester,
  ) async {
    for (var gesture = 0; gesture < 2; gesture++) {
      gestures.pointerDown(1, const Offset(100, 100));
      gestures.pointerDown(2, const Offset(140, 100));
      gestures.pointerMove(1, const Offset(100, 108.25));
      gestures.pointerMove(2, const Offset(140, 108.25));
      await tester.pump(const Duration(milliseconds: 16));
      gestures.pointerUp(1);
      gestures.pointerUp(2);
    }
    expect(inputs.map((input) => input['delta']), [24, 24]);
    gestures.dispose();
  });

  testWidgets('long press holds left down through drag until release', (
    tester,
  ) async {
    gestures.pointerDown(1, const Offset(100, 100));
    await tester.pump(const Duration(milliseconds: 449));
    expect(inputs, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(inputs.single['button'], 'left');
    expect(inputs.single['down'], isTrue);
    gestures.pointerMove(1, const Offset(140, 180));
    gestures.pointerUp(1);
    expect(inputs.map((input) => input['kind']), [
      'button',
      'pointer',
      'button',
    ]);
    expect(inputs.last['button'], 'left');
    expect(inputs.last['down'], isFalse);
    expect(inputs.last['x'], closeTo(.6, .00001));
    await tester.pump(const Duration(milliseconds: 100));
    expect(inputs, hasLength(3));
    gestures.dispose();
  });

  testWidgets('held button survives second contact until final lift', (
    tester,
  ) async {
    gestures.pointerDown(1, const Offset(100, 100));
    await tester.pump(const Duration(milliseconds: 450));
    gestures.pointerDown(2, const Offset(150, 100));
    gestures.pointerUp(1);
    expect(inputs, hasLength(1));
    gestures.pointerMove(2, const Offset(150, 200));
    gestures.pointerUp(2);
    expect(inputs.map((input) => input['button']), ['left', 'left']);
    expect(inputs.map((input) => input['down']), [true, false]);
    gestures.dispose();
  });

  testWidgets('moving before hold prevents long press and tap', (tester) async {
    gestures.pointerDown(1, const Offset(100, 100));
    gestures.pointerMove(1, const Offset(120, 100));
    gestures.pointerMove(1, const Offset(100, 100));
    await tester.pump(const Duration(milliseconds: 500));
    gestures.pointerUp(1);
    expect(inputs.where((input) => input['kind'] == 'button'), isEmpty);
    gestures.dispose();
  });

  testWidgets('stationary two-finger hold does not become a click', (
    tester,
  ) async {
    gestures.pointerDown(1, const Offset(100, 100));
    gestures.pointerDown(2, const Offset(140, 100));
    await tester.pump(const Duration(milliseconds: 450));
    gestures.pointerUp(1);
    gestures.pointerUp(2);
    expect(inputs, isEmpty);
    gestures.dispose();
  });

  testWidgets(
    'remote cursor echoes cannot rewind an active or recent gesture',
    (tester) async {
      gestures.syncRemoteCursor(const Offset(.2, .3));
      gestures.pointerDown(1, const Offset(100, 100));
      gestures.pointerMove(1, const Offset(140, 180));
      gestures.syncRemoteCursor(const Offset(.2, .3));
      expect(gestures.cursor.dx, closeTo(.3, .00001));
      await tester.pump(const Duration(seconds: 1));
      gestures.syncRemoteCursor(const Offset(.2, .3));
      expect(gestures.cursor.dx, closeTo(.3, .00001));
      gestures.pointerUp(1);
      await tester.pump(const Duration(milliseconds: 749));
      gestures.syncRemoteCursor(const Offset(.2, .3));
      expect(gestures.cursor.dx, closeTo(.3, .00001));
      await tester.pump(const Duration(milliseconds: 1));
      gestures.syncRemoteCursor(const Offset(.4, .5));
      expect(gestures.cursor, const Offset(.4, .5));
      gestures.dispose();
    },
  );

  testWidgets('pointer cancellation releases drag and discards queued motion', (
    tester,
  ) async {
    gestures.pointerDown(1, const Offset(100, 100));
    await tester.pump(const Duration(milliseconds: 450));
    gestures.pointerMove(1, const Offset(140, 180));
    gestures.pointerCancel(1);
    expect(inputs.map((input) => input['kind']), [
      'button',
      'button',
      'release',
    ]);
    expect(inputs[1]['down'], isFalse);
    await tester.pump(const Duration(seconds: 1));
    expect(inputs, hasLength(3));
    gestures.dispose();
  });

  testWidgets('cancelling one finger suppresses remaining contact until up', (
    tester,
  ) async {
    gestures.pointerDown(1, const Offset(100, 100));
    gestures.pointerDown(2, const Offset(140, 100));
    gestures.pointerCancel(1);
    gestures.pointerMove(2, const Offset(180, 140));
    gestures.pointerUp(2);
    expect(inputs, [
      {'kind': 'release'},
    ]);
    gestures.dispose();
  });

  testWidgets(
    'third contact cancels drag and suppresses all remaining fingers',
    (tester) async {
      gestures.pointerDown(1, const Offset(100, 100));
      await tester.pump(const Duration(milliseconds: 450));
      gestures.pointerDown(2, const Offset(140, 100));
      gestures.pointerDown(3, const Offset(180, 100));
      expect(inputs.map((input) => input['kind']), [
        'button',
        'button',
        'release',
      ]);
      expect(inputs[1]['down'], isFalse);
      gestures.pointerUp(3);
      gestures.pointerUp(2);
      gestures.pointerMove(1, const Offset(200, 200));
      gestures.pointerUp(1);
      await tester.pump(const Duration(milliseconds: 500));
      expect(inputs, hasLength(3));
      gestures.pointerDown(4, const Offset(200, 200));
      gestures.pointerUp(4);
      expect(inputs.last['button'], 'left');
      expect(inputs.last['down'], isFalse);
      gestures.dispose();
    },
  );

  testWidgets('cancel and dispose never leave delayed moves or clicks', (
    tester,
  ) async {
    gestures.pointerDown(1, const Offset(100, 100));
    gestures.pointerMove(1, const Offset(104, 104));
    gestures.cancel();
    gestures.pointerUp(1);
    gestures.dispose();
    final count = inputs.length;
    await tester.pump(const Duration(seconds: 2));
    expect(inputs, hasLength(count));
    expect(inputs.every((input) => input['kind'] == 'release'), isTrue);
  });
}
