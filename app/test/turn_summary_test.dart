import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/session_controller.dart';
import 'package:codeaw/data/timeline.dart';
import 'package:codeaw/ui/chat/composer.dart';
import 'package:codeaw/ui/chat/turn_summary.dart';
import 'package:codeaw/ui/chat/working_indicator.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final _start = DateTime.utc(2026, 10, 3, 12);

void _event(Timeline t, Map<String, dynamic> event, int seconds) {
  t.apply('_codeaw/event', {
    'event': event,
    '_meta': {
      'codeaw': {
        't': _start.add(Duration(seconds: seconds)).millisecondsSinceEpoch,
      },
    },
  });
  t.flush();
}

void _message(
  Timeline t,
  String mid,
  String text, {
  MessageRole role = MessageRole.agent,
  String? promptId,
  bool queued = false,
}) {
  t.apply('session/update', {
    'update': {
      'sessionUpdate': switch (role) {
        MessageRole.user => 'user_message_chunk',
        MessageRole.agent => 'agent_message_chunk',
        MessageRole.thought => 'agent_thought_chunk',
      },
      'content': {'type': 'text', 'text': text},
      '_meta': {
        'codeaw': {
          'mid': mid,
          'promptId': ?promptId,
          if (queued) 'queued': true,
        },
      },
    },
  });
  t.flush();
}

void _begin(Timeline t, String promptId, int seconds) => _event(t, {
  'type': 'state',
  'state': 'running',
  'turnPromptId': promptId,
  'turnStartedAt': _start
      .add(Duration(seconds: seconds))
      .millisecondsSinceEpoch,
}, seconds);

void _end(
  Timeline t,
  String promptId,
  int start,
  int end, {
  String reason = 'end_turn',
}) => _event(t, {
  'type': 'state',
  'state': 'idle',
  'stopReason': reason,
  'completedTurn': {
    'promptId': promptId,
    'startedAt': _start.add(Duration(seconds: start)).millisecondsSinceEpoch,
    'endedAt': _start.add(Duration(seconds: end)).millisecondsSinceEpoch,
  },
}, end);

Widget _wrap(Widget child, {double scale = 1}) => MaterialApp(
  home: Scaffold(
    body: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: child,
    ),
  ),
);

void main() {
  test(
    'keeps each queued turn separate, includes thoughts, freezes duration, and deduplicates completion',
    () {
      final t = Timeline();
      _message(t, 'u-p1', '第一個提示', role: MessageRole.user, promptId: 'p1');
      _begin(t, 'p1', 0);
      _message(t, 'm1', 'abcd');
      _message(t, 'm1', 'efgh');
      _message(t, 'think1', '思考', role: MessageRole.thought);
      _message(
        t,
        'u-p2',
        '排隊提示',
        role: MessageRole.user,
        promptId: 'p2',
        queued: true,
      );
      _event(t, {
        'type': 'state',
        'state': 'requires_action',
        'turnStartedAt': _start.millisecondsSinceEpoch,
      }, 1);
      _event(t, {
        'type': 'state',
        'state': 'running',
        'turnStartedAt': _start.millisecondsSinceEpoch,
      }, 3);
      _message(t, 'm2', '完成');
      expect(t.currentTurn!.estimatedTokens, 6);
      _end(t, 'p1', 0, 4);
      final first = t.items.whereType<TurnSummaryItem>().single;
      expect(first.responseText, 'abcdefgh\n\n完成');
      expect(first.thoughtText, '思考');
      expect(first.prompt!.text, '第一個提示');
      expect(
        first.elapsedAt(_start.add(const Duration(days: 1))),
        const Duration(seconds: 4),
      );
      expect(first.tokensPerSecondAt(_start), 1.5);
      _end(t, 'p1', 0, 4);
      expect(t.items.whereType<TurnSummaryItem>(), hasLength(1));

      _event(t, {'type': 'dequeued', 'promptId': 'p2'}, 4);
      _begin(t, 'p2', 4);
      expect(t.currentTurn!.estimatedTokens, 0);
      _message(t, 'm3', '第二回覆');
      _end(t, 'p2', 4, 6, reason: 'cancelled');
      final second = t.items.whereType<TurnSummaryItem>().last;
      expect(second.prompt!.text, '排隊提示');
      expect(second.responseText, '第二回覆');
      expect(second.estimatedTokens, 4);
      expect(t.items.last, same(second));
      t.clear();
      expect(t.currentTurn, isNull);
      expect(t.items, isEmpty);
      t.dispose();
    },
  );

  testWidgets(
    'shows live estimated TPS and preserves the final footer after idle',
    (tester) async {
      final t = Timeline();
      _begin(t, 'p1', 0);
      var now = _start;
      await tester.pumpWidget(
        _wrap(WorkingIndicator(timeline: t, now: () => now)),
      );
      expect(find.text('— TPS'), findsOneWidget);
      _message(t, 'm1', 'abcdefgh');
      now = _start.add(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('≈1.0 TPS'), findsOneWidget);
      _end(t, 'p1', 0, 2);
      await tester.pump();
      expect(find.textContaining('TPS'), findsNothing);
      await tester.pumpWidget(
        _wrap(
          TurnSummaryView(turn: t.items.whereType<TurnSummaryItem>().single),
        ),
      );
      expect(find.text('≈1.0 TPS'), findsOneWidget);
      expect(find.text('耗時 2 秒'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      t.dispose();
    },
  );

  testWidgets(
    'copies the complete response and transcript, and reuses the prompt in the composer',
    (tester) async {
      final client = BridgeClient(
        HostConfig(
          name: 'test',
          urls: ['ws://localhost/acp'],
          token: 'test',
          deviceId: 'test',
          deviceName: 'test',
        ),
      );
      final c = SessionController(client, 'fake:test');
      final t = c.timeline;
      _message(t, 'u-p1', '原提示', role: MessageRole.user, promptId: 'p1');
      _begin(t, 'p1', 0);
      _message(t, 'thought', '思考內容', role: MessageRole.thought);
      _message(t, 'm1', '前段');
      _message(t, 'm2', '後段');
      _end(t, 'p1', 0, 5);
      final turn = t.items.whereType<TurnSummaryItem>().single;
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      c.draft = '既有草稿';
      await tester.pumpWidget(
        _wrap(
          ListenableBuilder(
            listenable: c,
            builder: (_, _) => Column(
              children: [
                TurnSummaryView(
                  turn: turn,
                  onReusePrompt: () => c.reusePrompt(turn.prompt!),
                ),
                Composer(controller: c),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('複製回覆'));
      await tester.pump();
      expect(copied, '前段\n\n後段');
      await tester.tap(find.byTooltip('更多回合操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('複製整個回合'));
      await tester.pumpAndSettle();
      expect(copied, '你：\n原提示\n\nAgent：\n前段\n\n後段');
      await tester.tap(find.byTooltip('重新使用提示'));
      await tester.pump();
      expect(c.draft, '既有草稿\n\n原提示');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        c.draft,
      );
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      client.dispose();
    },
  );

  testWidgets(
    'fits on a narrow phone with large text and no generated response',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final t = Timeline();
      _begin(t, 'p1', 0);
      _end(t, 'p1', 0, 7384, reason: 'error');
      await tester.pumpWidget(
        _wrap(
          TurnSummaryView(turn: t.items.whereType<TurnSummaryItem>().single),
          scale: 1.8,
        ),
      );
      expect(find.text('耗時 2 小時 3 分 4 秒'), findsOneWidget);
      expect(find.text('— TPS'), findsOneWidget);
      expect(
      tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.copy_rounded)).onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      t.dispose();
    },
  );
}
