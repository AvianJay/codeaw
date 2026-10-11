import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/remote_desktop_controller.dart';
import 'package:codeaw/ui/common/adaptive.dart';
import 'package:codeaw/ui/remote_desktop/desktop_stream_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryStore extends HostStore {
  int writes = 0;

  @override
  Future<Map<String, dynamic>?> loadDesktopPreferences(HostConfig host) async =>
      null;

  @override
  Future<void> saveDesktopPreferences(
    HostConfig host,
    Map<String, dynamic> value,
  ) async {
    writes++;
  }
}

class _SheetHarness {
  _SheetHarness({bool dataSaver = false}) {
    controller =
        RemoteDesktopController(
            HostConfig(
              name: 'Settings test PC',
              urls: ['ws://localhost:7860/acp'],
              token: 'test',
              deviceId: 'test',
              deviceName: 'Phone',
            ),
            store,
            dataSaver: () => dataSaver,
          )
          ..hardware = true
          ..smoothAvailable = true;
  }

  final store = _MemoryStore();
  late final RemoteDesktopController controller;
  DesktopStreamPreferences? result;
  bool completed = false;

  Future<void> open(WidgetTester tester, {double textScale = 1}) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showAdaptiveSheet<DesktopStreamPreferences>(
                  context: context,
                  builder: (_) => DesktopStreamSettings(controller: controller),
                );
                completed = true;
              },
              child: const Text('開啟設定'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('開啟設定'));
    await tester.pumpAndSettle();
  }
}

Future<void> _chooseQuality(WidgetTester tester, String label) async {
  final dropdown = find.byType(DropdownButtonFormField<String>);
  await tester.ensureVisible(dropdown);
  await tester.tap(dropdown);
  await tester.pumpAndSettle();
  final item = find.text(label).last;
  await tester.ensureVisible(item);
  await tester.tap(item);
  await tester.pumpAndSettle();
}

Finder _fpsLabel(int fps) => find.descendant(
  of: find.byType(SegmentedButton<int>),
  matching: find.text(fps == 0 ? '自動' : '$fps FPS'),
);

Future<void> _chooseFps(WidgetTester tester, int fps) async {
  await tester.ensureVisible(_fpsLabel(fps));
  await tester.tap(_fpsLabel(fps));
  await tester.pumpAndSettle();
}

Future<void> _finish(WidgetTester tester, String label) async {
  final button = find.text(label);
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

SegmentedButton<int> _fpsControl(WidgetTester tester) =>
    tester.widget<SegmentedButton<int>>(find.byType(SegmentedButton<int>));

void main() {
  late _SheetHarness harness;

  setUp(() => harness = _SheetHarness());
  tearDown(() => harness.controller.dispose());

  testWidgets(
    'editing the draft and cancelling leaves the controller untouched',
    (tester) async {
      harness.controller
        ..preferredMode = DesktopMode.smooth
        ..preferredFps = 60;
      await harness.open(tester);
      await _chooseFps(tester, 30);
      await _chooseQuality(tester, '低流量');

      expect(harness.controller.preferredMode, DesktopMode.smooth);
      expect(harness.controller.preferredFps, 60);
      expect(harness.store.writes, 0);
      await _finish(tester, '取消');
      expect(harness.completed, isTrue);
      expect(harness.result, isNull);
      expect(harness.controller.preferredMode, DesktopMode.smooth);
      expect(harness.controller.preferredFps, 60);
      expect(harness.store.writes, 0);
    },
  );

  testWidgets('choosing automatic returns null quality and fps preferences', (
    tester,
  ) async {
    harness.controller
      ..preferredMode = DesktopMode.low
      ..preferredFps = 30;
    await harness.open(tester);
    await _chooseQuality(tester, '自動');
    await _chooseFps(tester, 0);
    await _finish(tester, '套用');

    expect(harness.completed, isTrue);
    expect(harness.result, isNotNull);
    expect(harness.result!.mode, isNull);
    expect(harness.result!.fps, isNull);
    expect(harness.controller.preferredMode, DesktopMode.low);
    expect(harness.controller.preferredFps, 30);
    expect(harness.store.writes, 0);
  });

  testWidgets('automatic quality can retain an explicit frame rate', (
    tester,
  ) async {
    await harness.open(tester);
    await _chooseFps(tester, 30);
    expect(find.text('套用後：高流暢 · 最高 30 FPS'), findsOneWidget);
    await _finish(tester, '套用');

    expect(harness.result!.mode, isNull);
    expect(harness.result!.fps, 30);
    expect(harness.controller.preferredFps, isNull);
    expect(harness.store.writes, 0);
  });

  testWidgets('software encoding disables new 60 fps selection', (
    tester,
  ) async {
    harness.controller.hardware = false;
    await harness.open(tester);
    final sixty = _fpsControl(
      tester,
    ).segments.singleWhere((segment) => segment.value == 60);
    expect(sixty.enabled, isFalse);
    await _chooseFps(tester, 60);
    expect(_fpsControl(tester).selected, {0});
    expect(find.text('套用後：高流暢 · 最高 30 FPS'), findsOneWidget);
    await _finish(tester, '套用');
    expect(harness.result!.fps, isNull);
  });

  testWidgets('software encoding preserves an existing 60 fps preference', (
    tester,
  ) async {
    harness.controller
      ..hardware = false
      ..preferredMode = DesktopMode.smooth
      ..preferredFps = 60;
    await harness.open(tester);

    expect(_fpsControl(tester).selected, {60});
    expect(find.text('目前最高支援 30 FPS；會保留 60 FPS 選擇，支援時再使用。'), findsOneWidget);
    expect(find.text('套用後：高流暢 · 最高 30 FPS'), findsOneWidget);
    await _finish(tester, '套用');
    expect(harness.result!.mode, DesktopMode.smooth);
    expect(harness.result!.fps, 60);
  });

  testWidgets('fixed-rate quality disables fps without discarding its draft', (
    tester,
  ) async {
    await harness.open(tester);
    await _chooseFps(tester, 30);
    await _chooseQuality(tester, '低流量');

    expect(_fpsControl(tester).onSelectionChanged, isNull);
    expect(_fpsControl(tester).selected, {30});
    expect(find.text('套用後：低流量 · 最高 2 FPS'), findsOneWidget);
    await _chooseFps(tester, 60);
    expect(_fpsControl(tester).selected, {30});
    await _chooseQuality(tester, '高流暢');
    expect(_fpsControl(tester).onSelectionChanged, isNotNull);
    expect(_fpsControl(tester).selected, {30});
    expect(find.text('套用後：高流暢 · 最高 30 FPS'), findsOneWidget);
    await _finish(tester, '套用');
    expect(harness.result!.mode, DesktopMode.smooth);
    expect(harness.result!.fps, 30);
  });

  testWidgets('unavailable smooth streaming previews its balanced fallback', (
    tester,
  ) async {
    harness.controller.smoothAvailable = false;
    await harness.open(tester);
    await _chooseQuality(tester, '高流暢');

    expect(find.text('套用後：一般 · 最高 15 FPS'), findsOneWidget);
    expect(find.text('這台電腦目前無法使用高流暢，會先改用一般。'), findsOneWidget);
    expect(_fpsControl(tester).onSelectionChanged, isNull);
    await _finish(tester, '套用');
    expect(harness.result!.mode, DesktopMode.smooth);
    expect(harness.result!.fps, isNull);
  });

  testWidgets('manual quality preview takes priority over global data saver', (
    tester,
  ) async {
    harness.controller.dispose();
    harness = _SheetHarness(dataSaver: true);
    await harness.open(tester);
    expect(find.text('套用後：低流量 · 最高 2 FPS'), findsOneWidget);
    await _chooseQuality(tester, '高流暢');
    expect(find.text('套用後：高流暢 · 最高 60 FPS'), findsOneWidget);
    expect(find.text('手動選擇畫質會優先於全域省流量設定。'), findsOneWidget);
    await _finish(tester, '套用');
    expect(harness.result!.mode, DesktopMode.smooth);
    expect(harness.result!.fps, isNull);
  });

  testWidgets(
    'large text on a narrow phone scrolls to an accessible apply button',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await harness.open(tester, textScale: 2);
      expect(tester.takeException(), isNull);
      expect(_fpsControl(tester).direction, Axis.vertical);

      await _chooseQuality(tester, '高流暢');
      await _chooseFps(tester, 30);
      expect(tester.takeException(), isNull);
      await _finish(tester, '套用');
      expect(tester.takeException(), isNull);
      expect(harness.completed, isTrue);
      expect(harness.result!.mode, DesktopMode.smooth);
      expect(harness.result!.fps, 30);
    },
  );
}
