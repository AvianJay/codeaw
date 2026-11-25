import 'package:codeaw/acp/jsonrpc.dart';
import 'package:codeaw/app_state.dart';
import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/session_controller.dart';
import 'package:codeaw/data/timeline.dart';
import 'package:codeaw/ui/chat/chat_page.dart';
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
    expect(find.text('0 秒'), findsOneWidget);
    expect(find.bySemanticsLabel('已處理 0 秒'), findsOneWidget);
    // No speed placeholder before the turn has written anything.
    expect(find.textContaining('TPS'), findsNothing);

    now = _start.add(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('2 秒'), findsOneWidget);
    _update(timeline, {
      'sessionUpdate': 'agent_message_chunk',
      'content': {'type': 'text', 'text': '回答'},
    });
    await tester.pump();
    expect(find.text('回覆中…'), findsOneWidget);
    expect(find.text('2 秒'), findsOneWidget);

    _update(timeline, {
      'sessionUpdate': 'user_message_chunk',
      'content': {'type': 'text', 'text': '下一則'},
    });
    _state(timeline, 'running', start: _start, queued: 2);
    await tester.pump();
    expect(find.text('回覆中…'), findsOneWidget);
    expect(find.text('還有 2 則排隊'), findsOneWidget);
    expect(find.text('2 秒'), findsOneWidget);

    _state(timeline, 'requires_action', start: _start, queued: 2);
    now = _start.add(const Duration(seconds: 65));
    await tester.pump(const Duration(seconds: 1));
    // Waiting for an answer is not timed: only the status and the queue remain.
    expect(find.text('等待批准…'), findsOneWidget);
    expect(find.textContaining('秒'), findsNothing);
    expect(find.text('還有 2 則排隊'), findsOneWidget);

    _state(timeline, 'idle');
    await tester.pump();
    expect(find.textContaining('秒'), findsNothing);
    _state(timeline, 'running', start: now);
    await tester.pump();
    expect(find.text('思考中…'), findsOneWidget);
    expect(find.text('0 秒'), findsOneWidget);
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
    expect(find.text('2 小時 3 分 4 秒'), findsOneWidget);
    expect(tester.takeException(), isNull);

    _state(timeline, 'requires_action', start: _start, queued: 12);
    await tester.pumpWidget(_wrap(WorkingIndicator(timeline: timeline, waitingForInput: true, now: () => _start.subtract(const Duration(seconds: 10))), textScale: 1.8));
    expect(find.text('等待你的回覆…'), findsOneWidget);
    expect(find.textContaining('秒'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    timeline.dispose();
  });

  testWidgets('a chat leaves the waiting line to its own request bar', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final host = HostConfig(name: 'PC', urls: ['ws://fixture/acp'], token: 'fixture', deviceId: 'fixture', deviceName: 'phone');
    final client = BridgeClient(host)..status = ConnStatus.online;
    final state = AppState(HostStore(), openSession: (_) {})
      ..host = host
      ..client = client
      ..loaded = true;
    state.hub = SessionHub(client);
    const id = 'claude:wait';
    final c = state.hub!.adopt(id, '/work', {
      '_meta': {
        'codeaw': {'lastSeq': 0},
      },
    });
    void turn(int queued) => c.onMessage(
      SessionMessage('_codeaw/event', {
        'sessionId': id,
        'event': {'type': 'state', 'state': 'requires_action', 'queued': queued, 'turnStartedAt': _start.millisecondsSinceEpoch},
      }),
    );
    c.onMessage(
      SessionMessage('session/update', {
        'sessionId': id,
        'update': {
          'sessionUpdate': 'user_message_chunk',
          'content': {'type': 'text', 'text': 'run the tests'},
          '_meta': {
            'codeaw': {'mid': 'u1'},
          },
        },
      }),
    );
    turn(0);
    c.timeline.flush();
    await tester.pumpWidget(
      AppScope(
        state: state,
        child: MaterialApp(home: ChatPage(sessionId: id, cwd: '/work')),
      ),
    );
    await tester.pump();
    // Asked on another device: nothing else on this screen says so.
    expect(find.text('等待批准…'), findsOneWidget);

    final token = CancelToken();
    c.onServerRequest('session/request_permission', {
      'sessionId': id,
      'toolCall': {
        'toolCallId': 'b1',
        'title': 'npm test',
        'kind': 'execute',
        'rawInput': {'command': 'npm test'},
      },
      'options': [
        {'optionId': 'allow', 'name': 'Allow', 'kind': 'allow_once'},
        {'optionId': 'reject', 'name': 'Reject', 'kind': 'reject_once'},
      ],
      '_meta': {
        'codeaw': {'requestId': 'r1'},
      },
    }, token);
    await tester.pump();
    expect(find.textContaining('需要批准'), findsOneWidget);
    expect(find.text('等待批准…'), findsNothing);

    // A queue is only shown on the line, so it comes back with one.
    turn(2);
    c.timeline.flush();
    await tester.pump();
    expect(find.text('等待批准…'), findsOneWidget);
    expect(find.text('還有 2 則排隊'), findsOneWidget);
    expect(tester.takeException(), isNull);

    token.cancel();
    await tester.pumpWidget(const SizedBox());
    state.hub!.dispose();
    client.dispose();
  });
}
