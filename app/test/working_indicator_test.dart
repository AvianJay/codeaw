import 'package:codeaw/data/timeline.dart';
import 'package:codeaw/ui/chat/working_indicator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _start = DateTime.utc(2026, 10, 2, 12);

void _state(Timeline timeline, String state, {DateTime? start, int queued = 0}) {
  timeline.apply('_codeaw/event', {
    'event': {'type': 'state', 'state': state, 'queued': queued, if (start != null) 'turnStartedAt': start.millisecondsSinceEpoch},
    '_meta': {
      'codeaw': {'t': (start ?? _start).millisecondsSinceEpoch},
    },
  });
  timeline.flush();
}

void _update(Timeline timeline, Map<String, dynamic> update, {DateTime? at}) {
  timeline.apply('session/update', {
    'update': update,
    '_meta': {
      'codeaw': {'t': (at ?? _start).millisecondsSinceEpoch},
    },
  });
  timeline.flush();
}

Widget _wrap(Widget child, {Brightness brightness = Brightness.light, double textScale = 1}) => MaterialApp(
  theme: ThemeData(colorSchemeSeed: const Color(0xFF0F9D8A), brightness: brightness),
  home: Scaffold(
    body: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: child,
    ),
  ),
);

void main() {
  testWidgets('ticks through activity changes and waits, then resets for the next turn', (tester) async {
    final timeline = Timeline();
    var now = _start;
    _state(timeline, 'running', start: _start);
    await tester.pumpWidget(_wrap(WorkingIndicator(timeline: timeline, now: () => now)));
    expect(find.text('思考中…'), findsOneWidget);
    expect(find.text('已處理 0 秒'), findsOneWidget);

    now = _start.add(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('已處理 2 秒'), findsOneWidget);
    _update(timeline, {
      'sessionUpdate': 'agent_message_chunk',
      'content': {'type': 'text', 'text': '回答'},
    });
    await tester.pump();
    expect(find.text('回覆中…'), findsOneWidget);
    expect(find.text('已處理 2 秒'), findsOneWidget);

    _update(timeline, {
      'sessionUpdate': 'user_message_chunk',
      'content': {'type': 'text', 'text': '下一則'},
    });
    _state(timeline, 'running', start: _start, queued: 2);
    await tester.pump();
    expect(find.text('回覆中…'), findsOneWidget);
    expect(find.text('還有 2 則排隊'), findsOneWidget);
    expect(find.text('已處理 2 秒'), findsOneWidget);

    _state(timeline, 'requires_action', start: _start, queued: 2);
    now = _start.add(const Duration(seconds: 65));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('等待批准…'), findsOneWidget);
    expect(find.text('已處理 1 分 5 秒'), findsOneWidget);

    _state(timeline, 'idle');
    await tester.pump();
    expect(find.textContaining('已處理'), findsNothing);
    _state(timeline, 'running', start: now);
    await tester.pump();
    expect(find.text('思考中…'), findsOneWidget);
    expect(find.text('已處理 0 秒'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    timeline.dispose();
  });

  testWidgets('shows current tool details and keeps other active tools visible', (tester) async {
    final timeline = Timeline();
    _state(timeline, 'running', start: _start);
    _update(timeline, {'sessionUpdate': 'tool_call', 'toolCallId': 'read', 'kind': 'read', 'title': 'app/lib/main.dart', 'status': 'in_progress'});
    await tester.pumpWidget(_wrap(WorkingIndicator(timeline: timeline, now: () => _start)));
    expect(find.text('讀取檔案中…'), findsOneWidget);
    expect(find.text('app/lib/main.dart'), findsOneWidget);

    _update(timeline, {'sessionUpdate': 'tool_call', 'toolCallId': 'exec', 'kind': 'execute', 'title': 'flutter test', 'status': 'in_progress'});
    await tester.pump();
    expect(find.text('執行指令中…'), findsOneWidget);
    _update(timeline, {'sessionUpdate': 'tool_call_update', 'toolCallId': 'exec', 'title': 'flutter analyze'});
    await tester.pump();
    expect(find.text('flutter analyze'), findsOneWidget);

    _update(timeline, {'sessionUpdate': 'tool_call_update', 'toolCallId': 'exec', 'status': 'completed'});
    await tester.pump();
    expect(find.text('讀取檔案中…'), findsOneWidget);
    _update(timeline, {'sessionUpdate': 'tool_call_update', 'toolCallId': 'read', 'status': 'failed'});
    await tester.pump();
    expect(find.text('思考中…'), findsOneWidget);
    expect(find.text('app/lib/main.dart'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    timeline.dispose();
  });

  test('full replay keeps current activity and filters tools from earlier turns', () {
    final timeline = Timeline();
    _update(timeline, {'sessionUpdate': 'tool_call', 'toolCallId': 'old', 'kind': 'read', 'status': 'in_progress'}, at: _start.subtract(const Duration(minutes: 5)));
    _update(timeline, {
      'sessionUpdate': 'agent_message_chunk',
      'content': {'type': 'text', 'text': 'old answer'},
    }, at: _start.subtract(const Duration(minutes: 4)));
    _update(timeline, {'sessionUpdate': 'tool_call', 'toolCallId': 'current', 'kind': 'edit', 'status': 'in_progress'}, at: _start.add(const Duration(seconds: 1)));
    _state(timeline, 'running', start: _start);
    expect(timeline.activeTool?.toolCallId, 'current');
    expect(timeline.turnStartedAt, _start);
    _state(timeline, 'requires_action', start: _start, queued: 1);
    _state(timeline, 'running', start: _start, queued: 2);
    expect(timeline.turnStartedAt, _start);
    expect(timeline.activeTool?.toolCallId, 'current');
    timeline.clear();
    expect(timeline.running, isFalse);
    expect(timeline.turnStartedAt, isNull);
    expect(timeline.activeTool, isNull);
    timeline.dispose();
  });

  testWidgets('fits long tool names and elapsed hours on a small phone with large text', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final timeline = Timeline();
    _state(timeline, 'running', start: _start, queued: 12);
    _update(timeline, {'sessionUpdate': 'tool_call', 'toolCallId': 'edit', 'kind': 'edit', 'title': '修改 app/lib/ui/chat/very_long_file_name.dart 並更新狀態', 'status': 'in_progress'});
    final now = _start.add(const Duration(hours: 2, minutes: 3, seconds: 4));
    await tester.pumpWidget(
      _wrap(
        WorkingIndicator(timeline: timeline, now: () => now),
        brightness: Brightness.dark,
        textScale: 1.8,
      ),
    );
    expect(find.text('修改檔案中…'), findsOneWidget);
    expect(find.text('已處理 2 小時 3 分 4 秒'), findsOneWidget);
    expect(tester.takeException(), isNull);

    _state(timeline, 'requires_action', start: _start, queued: 12);
    await tester.pumpWidget(_wrap(WorkingIndicator(timeline: timeline, waitingForInput: true, now: () => _start.subtract(const Duration(seconds: 10))), textScale: 1.8));
    expect(find.text('等待你的回覆…'), findsOneWidget);
    expect(find.text('已處理 0 秒'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    timeline.dispose();
  });
}
