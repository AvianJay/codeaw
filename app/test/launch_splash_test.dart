import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:codeaw/ui/common/app_theme.dart';
import 'package:codeaw/ui/common/codeaw_icon.dart';
import 'package:codeaw/ui/common/launch_splash.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for the app under the splash and counts how often its State is created.
class _App extends StatefulWidget {
  const _App();

  static var created = 0;

  @override
  State<_App> createState() => _AppState();
}

class _AppState extends State<_App> {
  @override
  void initState() {
    super.initState();
    _App.created++;
  }

  @override
  Widget build(BuildContext context) => const ColoredBox(color: Color(0xFF3366FF));
}

final _overlay = find.descendant(of: find.byType(LaunchSplash), matching: find.byType(CustomPaint));

/// Pumps frames of [frame] until [duration] has passed.
Future<void> _pumpFor(WidgetTester tester, Duration duration, {Duration frame = const Duration(milliseconds: 16)}) async {
  for (var t = Duration.zero; t < duration; t += frame) {
    await tester.pump(frame);
  }
}

Widget _switchable(ValueNotifier<bool> ready, {Widget child = const _App()}) => ValueListenableBuilder(
  valueListenable: ready,
  builder: (_, value, _) => LaunchSplash(ready: value, child: child),
);

/// Renders the overlay as physical pixels.
Future<(ByteData, int, int)> _capture(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.descendant(of: find.byType(LaunchSplash), matching: find.byType(RepaintBoundary)),
  );
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: tester.view.devicePixelRatio);
    return ((await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!, image.width, image.height);
  }))!;
}

void main() {
  testWidgets('covers the app until it is ready, then zooms open onto it', (tester) async {
    final ready = ValueNotifier(false);
    addTearDown(ready.dispose);
    await tester.pumpWidget(_switchable(ready));
    await _pumpFor(tester, const Duration(seconds: 3));
    expect(_overlay, findsOneWidget);
    ready.value = true;
    await _pumpFor(tester, const Duration(milliseconds: 300));
    expect(_overlay, findsOneWidget);
    await _pumpFor(tester, const Duration(milliseconds: 250));
    expect(_overlay, findsNothing);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets(
    'plays about a second when the app is ready at once',
    (tester) async {
      // iOS holds the first frame longer while its launch storyboard fades out.
      final length = Duration(milliseconds: defaultTargetPlatform == TargetPlatform.iOS ? 1130 : 1030);
      await tester.pumpWidget(const LaunchSplash(ready: true, child: _App()));
      await _pumpFor(tester, length - const Duration(milliseconds: 80));
      expect(_overlay, findsOneWidget);
      await _pumpFor(tester, const Duration(milliseconds: 120));
      expect(_overlay, findsNothing);
    },
    variant: const TargetPlatformVariant({TargetPlatform.android, TargetPlatform.iOS}),
  );

  testWidgets('keeps the state of the app it covers', (tester) async {
    _App.created = 0;
    await tester.pumpWidget(const LaunchSplash(ready: true, child: _App()));
    final before = tester.state(find.byType(_App));
    await tester.pumpAndSettle();
    expect(_overlay, findsNothing);
    expect(tester.state(find.byType(_App)), same(before));
    expect(_App.created, 1);
  });

  for (final features in const [
    FakeAccessibilityFeatures(disableAnimations: true),
    FakeAccessibilityFeatures(reduceMotion: true),
  ]) {
    testWidgets('stays still and leaves once ready when motion is reduced (${features.disableAnimations ? 'Android' : 'iOS'})', (
      tester,
    ) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue = features;
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      final ready = ValueNotifier(false);
      addTearDown(ready.dispose);
      await tester.pumpWidget(_switchable(ready));
      expect(_overlay, findsOneWidget);
      expect(tester.binding.hasScheduledFrame, isFalse);
      ready.value = true;
      await tester.pump();
      expect(_overlay, findsNothing);
    });
  }

  testWidgets('a tap starts the exit straight away and does not reach the app', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      LaunchSplash(
        ready: true,
        child: GestureDetector(onTap: () => taps++, child: const ColoredBox(color: Color(0xFF3366FF))),
      ),
    );
    await _pumpFor(tester, const Duration(milliseconds: 200));
    await tester.tapAt(const Offset(400, 300));
    await _pumpFor(tester, const Duration(milliseconds: 500));
    expect(_overlay, findsNothing);
    expect(taps, 0);
  });

  for (final size in const [Size(390, 844), Size(844, 390), Size(1024, 1366), Size(600, 600)]) {
    testWidgets('paints every phase and ends fully open at ${size.width.toInt()}x${size.height.toInt()}', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const LaunchSplash(ready: true, child: _App()));
      // The first tick only starts the clock. The exit then starts at 580 ms (100 ms hold +
      // 480 ms intro) and ends at 1030 ms; stop 1 ms short of the end.
      await tester.pump(const Duration(milliseconds: 16));
      await _pumpFor(tester, const Duration(milliseconds: 580), frame: const Duration(milliseconds: 20));
      await _pumpFor(tester, const Duration(milliseconds: 440), frame: const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 9));
      expect(_overlay, findsOneWidget);
      final (pixels, _, _) = await _capture(tester);
      var opaque = 0;
      for (var i = 3; i < pixels.lengthInBytes; i += 4) {
        if (pixels.getUint8(i) != 0) opaque++;
      }
      expect(opaque, 0, reason: 'the bubble should cover the whole screen by the end');
      await tester.pump(const Duration(milliseconds: 16));
      expect(_overlay, findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final brightness in Brightness.values) {
    testWidgets('first frame matches the iOS launch image (${brightness.name})', (tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      tester.platformDispatcher.platformBrightnessTestValue = brightness;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await tester.pumpWidget(const LaunchSplash(ready: false, child: _App()));
      final (actual, width, height) = await _capture(tester);
      final launch = (await tester.runAsync(() async {
        final bytes = File('ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage@3x.png').readAsBytesSync();
        final image = (await (await ui.instantiateImageCodec(bytes)).getNextFrame()).image;
        return (await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!;
      }))!;
      final surface = brightness == Brightness.dark ? codeawSurfaceDark : codeawSurfaceLight;
      final background = [surface.r, surface.g, surface.b].map((c) => (c * 255).round()).toList();
      // The storyboard centres the 288 pt image; count pixels that clearly differ from it.
      int mismatches(int shift) {
        const side = 864;
        final left = (width - side) ~/ 2 + shift, top = (height - side) ~/ 2;
        var count = 0;
        for (var y = 0; y < height; y++) {
          for (var x = 0; x < width; x++) {
            final i = (y * width + x) * 4;
            final lx = x - left, ly = y - top;
            final inside = lx >= 0 && ly >= 0 && lx < side && ly < side;
            final j = (ly * side + lx) * 4;
            final alpha = inside ? launch.getUint8(j + 3) / 255 : 0.0;
            for (var c = 0; c < 3; c++) {
              final over = inside ? launch.getUint8(j + c) : 0;
              final expected = over * alpha + background[c] * (1 - alpha);
              if ((actual.getUint8(i + c) - expected).abs() > 48) {
                count++;
                break;
              }
            }
          }
        }
        return count;
      }

      // Pillow and Skia anti-alias edges a little differently (a few hundred pixels here), while
      // a 1 dp offset differs along every edge (about 6000).
      final aligned = mismatches(0), shifted = mismatches(3);
      expect(aligned, lessThan(shifted ~/ 10));
      expect(aligned, lessThan(1000));
    });
  }

  test('native launch screens use the theme surfaces', () {
    Color android(String values) {
      final xml = File('android/app/src/main/res/$values/colors.xml').readAsStringSync();
      final hex = RegExp(r'<color name="app_surface">#([0-9A-F]{6})</color>').firstMatch(xml)![1]!;
      return Color(int.parse('FF$hex', radix: 16));
    }

    expect(android('values'), codeawSurfaceLight);
    expect(android('values-night'), codeawSurfaceDark);
    final colorset = jsonDecode(
      File('ios/Runner/Assets.xcassets/LaunchBackground.colorset/Contents.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    Color ios(bool dark) {
      final entry = (colorset['colors'] as List).cast<Map<String, dynamic>>().singleWhere(
        (c) => (c['appearances'] != null) == dark,
      );
      final components = (entry['color'] as Map<String, dynamic>)['components'] as Map<String, dynamic>;
      int channel(String name) => int.parse((components[name] as String).substring(2), radix: 16);
      return Color.fromARGB(255, channel('red'), channel('green'), channel('blue'));
    }

    expect(ios(false), codeawSurfaceLight);
    expect(ios(true), codeawSurfaceDark);
  });

  test('the Dart icon paths match the Android drawables', () {
    List<String> paths(String drawable) => RegExp(r'android:pathData="([^"]+)"')
        .allMatches(File('android/app/src/main/res/drawable/$drawable.xml').readAsStringSync())
        .map((m) => m[1]!)
        .toList();

    expect(paths('ic_launcher_foreground'), [codeawIconBubble, codeawIconChevron + codeawIconUnderscore]);
    expect(paths('splash_icon').last, codeawIconBubble);
  });

  // Opt-in, for eyeballing: $env:CODEAW_SCREENSHOTS=1; flutter test --update-goldens test/launch_splash_test.dart
  testWidgets(
    'screenshots of each phase',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        LaunchSplash(
          ready: true,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: codeawTheme(Brightness.light),
            home: Scaffold(
              appBar: AppBar(title: const Text('codeaw')),
              body: ListView(children: [for (var i = 0; i < 12; i++) ListTile(title: Text('Session $i'))]),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 16));
      var now = 0;
      for (final at in [0, 160, 240, 300, 440, 560, 620, 680, 740, 820, 900, 980, 1020]) {
        await _pumpFor(tester, Duration(milliseconds: at - now), frame: const Duration(milliseconds: 20));
        now = at;
        await expectLater(find.byType(LaunchSplash), matchesGoldenFile('screenshots/launch_${'$at'.padLeft(4, '0')}.png'));
      }
    },
    skip: Platform.environment['CODEAW_SCREENSHOTS'] != '1',
  );
}
