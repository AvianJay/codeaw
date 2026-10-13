import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/session_controller.dart';
import 'package:codeaw/data/timeline.dart';
import 'package:codeaw/ui/chat/items.dart';
import 'package:codeaw/ui/chat/working_indicator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _start = DateTime.utc(2026, 10, 7, 6);

SessionController _controller(String agent, {String? model}) =>
    SessionController(
      BridgeClient(
        HostConfig(
          name: 'test',
          urls: ['ws://localhost:1'],
          token: 'test',
          deviceId: 'test',
          deviceName: 'test',
        ),
      ),
      '$agent:test',
    )..timeline.configOptions = model == null ? null : [_model(model)];

Map<String, dynamic> _model(String value) => {
  'id': 'model',
  'name': 'Model',
  'category': 'model',
  'type': 'select',
  'currentValue': value,
  'options': [
    {'value': value, 'name': value},
  ],
};

void _thought(SessionController c, String id, String text) {
  c.timeline.apply('session/update', {
    'update': {
      'sessionUpdate': 'agent_thought_chunk',
      'content': {'type': 'text', 'text': text},
      '_meta': {
        'codeaw': {'mid': id},
      },
    },
    '_meta': {
      'codeaw': {
        't': _start.add(const Duration(seconds: 1)).millisecondsSinceEpoch,
      },
    },
  });
  c.timeline.flush();
}

Widget _conversation(SessionController c) => MaterialApp(
  home: Scaffold(
    body: ListenableBuilder(
      listenable: c.timeline,
      builder: (context, _) => ListView(
        children: [
          for (final item in chatTimelineItems(c))
            TimelineItemView(
              key: ValueKey(item.key),
              item: item,
              controller: c,
              isLast: false,
            ),
          WorkingIndicator(
            timeline: c.timeline,
            showThoughts: c.thoughtSummary,
            now: () => _start,
          ),
        ],
      ),
    ),
  ),
);

void main() {
  for (final (agent, model) in <(String, String?)>[
    ('codex', null),
    ('omp', 'gpt-5.2-codex'),
    ('claude', 'openai/gpt-5'),
  ]) {
    testWidgets(
      '$agent${model == null ? '' : ' running $model'} previews the latest section, updates streamed chunks, and archives all thoughts after completion',
      (tester) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final c = _controller(agent, model: model);
        addTearDown(c.dispose);
        addTearDown(c.client.dispose);
        expect(c.thoughtSummary, isTrue);
        c.timeline.setTurnState(
          'running',
          startedAt: _start.millisecondsSinceEpoch,
          promptId: 'p1',
        );
        _thought(c, 'first', '**Asking for business intent**');
        _thought(c, 'second', '**Checking Android SDK tools**');
        await tester.pumpWidget(_conversation(c));
        expect(find.byType(ThoughtView), findsNothing);
        expect(find.text('Asking for business intent'), findsNothing);
        final latest = find.text('Checking Android SDK tools');
        expect(
          find.descendant(of: find.byType(WorkingIndicator), matching: latest),
          findsOneWidget,
        );
        expect(find.textContaining('**'), findsNothing);

        // Updating an existing thought does not notify the entire timeline.
        var timelineUpdates = 0;
        c.timeline.addListener(() => timelineUpdates++);
        _thought(c, 'second', '\n**Filtering OTA endpoint metadata**');
        await tester.pump();
        expect(timelineUpdates, 0);
        expect(find.text('Filtering OTA endpoint metadata'), findsOneWidget);
        expect(find.text('Checking Android SDK tools'), findsNothing);
        await tester.tap(find.text('Filtering OTA endpoint metadata'));
        await tester.pump();
        expect(
          find.textContaining('Asking for business intent', findRichText: true),
          findsOneWidget,
        );
        expect(
          find.textContaining('Checking Android SDK tools', findRichText: true),
          findsOneWidget,
        );
        expect(find.textContaining('**'), findsNothing);
        expect(tester.takeException(), isNull);

        c.timeline.apply('_codeaw/event', {
          'event': {
            'type': 'state',
            'state': 'idle',
            'stopReason': 'end_turn',
            'completedTurn': {
              'promptId': 'p1',
              'startedAt': _start.millisecondsSinceEpoch,
              'endedAt': _start
                  .add(const Duration(seconds: 5))
                  .millisecondsSinceEpoch,
            },
          },
        });
        c.timeline.flush();
        await tester.pump();
        expect(find.byType(ThoughtView), findsNothing);
        expect(find.text('思考中…'), findsNothing);
        expect(find.text('思考摘要'), findsOneWidget);
        expect(
          find.textContaining('Asking for business intent', findRichText: true),
          findsNothing,
        );
        await tester.tap(find.text('思考摘要'));
        await tester.pump();
        expect(
          find.textContaining('Asking for business intent', findRichText: true),
          findsOneWidget,
        );
        final saved = c.timeline.items.whereType<TurnSummaryItem>().single;
        expect(
          saved.thoughtText,
          '**Asking for business intent**\n\n**Checking Android SDK tools**\n**Filtering OTA endpoint metadata**',
        );
        expect(
          c.timeline.items.whereType<MessageItem>().where(
            (m) => m.role == MessageRole.thought,
          ),
          hasLength(2),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'other models keep raw inline thoughts; Codex and GPT render thoughts without turn metadata as Markdown',
    (tester) async {
      for (final (agent, model, summary) in <(String, String?, bool)>[
        ('claude', null, false),
        ('kimi', null, false),
        ('omp', 'anthropic/claude-sonnet-4-5', false),
        ('omp', 'local-model', false),
        ('codex', null, true),
        ('omp', 'gpt-5.2', true),
      ]) {
        final reason = '$agent $model';
        final c = _controller(agent, model: model);
        if (!summary) {
          c.timeline.setTurnState(
            'running',
            startedAt: _start.millisecondsSinceEpoch,
          );
        }
        _thought(c, 'legacy', '**Existing thought**\n\nChecking `details`');
        await tester.pumpWidget(_conversation(c));
        expect(find.byType(ThoughtView), findsOneWidget, reason: reason);
        expect(
          find.text(summary ? 'Existing thought' : '**Existing thought**'),
          findsOneWidget,
          reason: reason,
        );
        expect(
          find.textContaining('Checking', findRichText: true),
          findsNothing,
          reason: reason,
        );
        await tester.tap(find.byType(ThoughtView));
        await tester.pump();
        expect(
          find.textContaining('Checking', findRichText: true),
          findsWidgets,
          reason: reason,
        );
        expect(
          find.textContaining('**', findRichText: true),
          summary ? findsNothing : findsWidgets,
          reason: reason,
        );
        expect(tester.takeException(), isNull, reason: reason);
        await tester.pumpWidget(const SizedBox());
        c.dispose();
        c.client.dispose();
      }
    },
  );

  testWidgets('a model change to GPT folds the running turn\'s thoughts', (
    tester,
  ) async {
    final c = _controller('omp');
    addTearDown(c.dispose);
    addTearDown(c.client.dispose);
    c.timeline.setTurnState(
      'running',
      startedAt: _start.millisecondsSinceEpoch,
      promptId: 'p1',
    );
    _thought(c, 'first', '**Planning the change**');
    await tester.pumpWidget(_conversation(c));
    expect(find.byType(ThoughtView), findsOneWidget);
    expect(find.text('**Planning the change**'), findsOneWidget);

    c.timeline.apply('session/update', {
      'update': {
        'sessionUpdate': 'config_option_update',
        'configOptions': [_model('gpt-5.2-codex')],
      },
    });
    c.timeline.flush();
    await tester.pump();
    expect(find.byType(ThoughtView), findsNothing);
    expect(
      find.descendant(
        of: find.byType(WorkingIndicator),
        matching: find.text('Planning the change'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('**'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
