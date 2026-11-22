import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/notifications.dart';
import 'package:codeaw/data/session_controller.dart';
import 'package:codeaw/data/timeline.dart';
import 'package:codeaw/ui/chat/agent_cards.dart';
import 'package:codeaw/ui/chat/items.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _Client extends BridgeClient {
  _Client()
    : super(
        HostConfig(
          name: 'fixture',
          urls: ['ws://pc.example:7860/acp'],
          token: 'device-token',
          deviceId: 'fixture',
          deviceName: 'fixture',
        ),
      ) {
    status = ConnStatus.online;
  }

  final prompts = <List<dynamic>>[];
  final states = <Map<String, dynamic>>[];

  @override
  Future<dynamic> request(String method, [Map<String, dynamic>? params]) async {
    if (method == 'session/prompt') prompts.add(params!['prompt'] as List);
    return <String, dynamic>{};
  }

  @override
  void notify(String method, [Map<String, dynamic>? params]) {
    if (method == '_codeaw/client/state') states.add(params!);
  }
}

Map<String, dynamic> _event(Map<String, dynamic> event) => {'sessionId': 'claude:one', 'event': event};

Map<String, dynamic> _card(String id, Map<String, dynamic> card) => _event({'type': 'card', 'cardId': id, 'card': card});

Map<String, dynamic> _replies(String id, List<String> replies) => _card(id, {'kind': 'replies', 'replies': replies});

void _say(Timeline t, String type, String mid, String text, {String? promptId}) {
  t.apply('session/update', {
    'update': {
      'sessionUpdate': type,
      'content': {'type': 'text', 'text': text},
      '_meta': {
        'codeaw': {'mid': mid, 'promptId': ?promptId},
      },
    },
  });
}

/// A whole turn: it starts running and ends, which adds its summary item.
void _turn(Timeline t, String promptId, int startedAt, void Function() during) {
  t.apply('_codeaw/event', _event({'type': 'state', 'state': 'running', 'queued': 0, 'turnStartedAt': startedAt, 'turnPromptId': promptId}));
  during();
  t.apply('_codeaw/event', _event({
    'type': 'state', 'state': 'idle', 'queued': 0, 'stopReason': 'end_turn',
    'completedTurn': {'promptId': promptId, 'startedAt': startedAt, 'endedAt': startedAt + 1000},
  }));
}

void main() {
  test('keeps a card once, in place, through replay and the saved history', () {
    final t = Timeline();
    final files = {
      'kind': 'files',
      'title': 'Results',
      'files': [
        {'path': r'C:\out\chart.png', 'name': 'chart.png', 'size': 2048, 'mimeType': 'image/png', 'caption': 'Latency'},
      ],
    };
    _say(t, 'agent_message_chunk', 'a1', 'Here is the chart.');
    t.apply('_codeaw/event', _card('k_1', files));
    // A reconnect can deliver the same entry again.
    t.apply('_codeaw/event', _card('k_1', files));
    _say(t, 'agent_message_chunk', 'a2', 'Anything else?');
    t.apply('_codeaw/event', _card('k_2', {'kind': 'hologram', 'beam': true}));
    t.flush();

    expect(t.items.map((item) => item.key), ['agent_message_chunk:a1', 'card:k_1', 'agent_message_chunk:a2', 'card:k_2']);
    final card = t.items.whereType<CardItem>().first;
    expect(card.kind, 'files');
    expect(card.inline, isTrue);
    expect(card.files.single['caption'], 'Latency');
    expect(card.replies, isEmpty);
    // A kind from a newer bridge is kept, and shown as nothing.
    expect(t.items.whereType<CardItem>().last.files, isEmpty);

    final restored = Timeline.fromSnapshot(t.toSnapshot());
    expect(restored.debugSnapshot(), t.debugSnapshot());
    expect(restored.items.whereType<CardItem>().first.card, files);
  });

  test('offers quick replies only until the user answers or another turn ends', () {
    final t = Timeline();
    expect(t.suggestedReplies, isEmpty);
    _say(t, 'user_message_chunk', 'u-p1', 'Fix the bug', promptId: 'p1');
    _turn(t, 'p1', 1000, () {
      t.apply('_codeaw/event', _replies('k_1', ['Yes, commit it', 'Run the tests first', '']));
      _say(t, 'agent_message_chunk', 'a1', 'Done. Commit?');
    });
    expect(t.suggestedReplies, ['Yes, commit it', 'Run the tests first']);
    final card = t.items.whereType<CardItem>().single;
    expect(card.inline, isFalse);

    // A background task's result is delivered as a user-role message; it is not an answer.
    _say(t, 'user_message_chunk', 'n1', '<task-notification><task-id>t</task-id><status>completed</status></task-notification>');
    expect(t.suggestedReplies, hasLength(2));

    // The turn it starts is.
    _turn(t, 'auto', 5000, () => _say(t, 'agent_message_chunk', 'a2', 'The background job finished.'));
    expect(t.suggestedReplies, isEmpty);

    final answered = Timeline();
    _turn(answered, 'p1', 1000, () => answered.apply('_codeaw/event', _replies('k_1', ['Yes'])));
    expect(answered.suggestedReplies, ['Yes']);
    // The local echo of a tapped reply counts at once, before the bridge confirms it.
    answered.addPendingPrompt('p2', [
      {'type': 'text', 'text': 'Yes'},
    ]);
    expect(answered.suggestedReplies, isEmpty);

    // A newer offer replaces an older one.
    final twice = Timeline();
    _turn(twice, 'p1', 1000, () {
      twice.apply('_codeaw/event', _replies('k_1', ['Old']));
      twice.apply('_codeaw/event', _replies('k_2', ['New']));
    });
    expect(twice.suggestedReplies, ['New']);
  });

  testWidgets('shows files with a preview from the bridge and opens them in the file viewer', (tester) async {
    final client = _Client();
    final controller = SessionController(client, 'claude:one', cwd: r'C:\work');
    final opened = <String>[];
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(
            body: ListenableBuilder(
              listenable: controller.timeline,
              builder: (context, _) => ListView(
                children: [
                  for (final item in chatTimelineItems(controller))
                    TimelineItemView(key: ValueKey(item.key), item: item, controller: controller, isLast: false),
                ],
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/file',
          builder: (_, state) {
            opened.add(state.uri.queryParameters['path']!);
            return const Scaffold(body: Text('file viewer'));
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    addTearDown(controller.dispose);
    addTearDown(client.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));

    controller.timeline.apply('_codeaw/event', _card('k_1', {
      'kind': 'files',
      'title': 'Results',
      'files': [
        {'path': r'C:\out\我的 chart #1.png', 'name': '我的 chart #1.png', 'size': 2048, 'mimeType': 'image/png', 'caption': 'Latency'},
        {'path': r'C:\out\report.pdf', 'name': 'report.pdf', 'size': 5 * 1024 * 1024, 'mimeType': 'application/pdf'},
        {'path': r'C:\out\logo.svg', 'name': 'logo.svg', 'size': 12, 'mimeType': 'image/svg+xml'},
      ],
    }));
    controller.timeline.apply('_codeaw/event', _replies('k_2', ['Looks good']));
    controller.timeline.apply('_codeaw/event', _card('k_3', {'kind': 'notice', 'title': 'CI', 'message': 'Build finished', 'urgent': true}));
    controller.timeline.flush();
    await tester.pump();

    expect(find.text('Results'), findsOneWidget);
    expect(find.text('我的 chart #1.png'), findsOneWidget);
    expect(find.text('2.0 KB · Latency'), findsOneWidget);
    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.text('5.0 MB'), findsOneWidget);
    // Only the decodable image is previewed, with this device's credentials and its exact path.
    final preview = tester.widget<Image>(find.byType(Image)).image as NetworkImage;
    expect(Uri.parse(preview.url).path, '/api/fs/raw');
    expect(Uri.parse(preview.url).queryParameters['path'], r'C:\out\我的 chart #1.png');
    expect(Uri.parse(preview.url).host, 'pc.example');
    expect(preview.headers, client.authHeaders);
    // Quick replies are not part of the conversation; the notice is.
    expect(find.text('Looks good'), findsNothing);
    expect(find.textContaining('Build finished', findRichText: true), findsOneWidget);
    expect(find.byIcon(Icons.notification_important_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('report.pdf'));
    await tester.pumpAndSettle();
    expect(opened, [r'C:\out\report.pdf']);
    expect(find.text('file viewer'), findsOneWidget);
  });

  testWidgets('sends a quick reply on tap and withdraws the offer', (tester) async {
    final client = _Client();
    final controller = SessionController(client, 'claude:one');
    addTearDown(controller.dispose);
    addTearDown(client.dispose);
    final timeline = controller.timeline;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListenableBuilder(
          listenable: Listenable.merge([controller, timeline]),
          builder: (context, _) => SuggestedReplies(controller: controller),
        ),
      ),
    ));
    expect(find.byType(InkWell), findsNothing);

    // Offered during the turn, shown once it has ended.
    timeline.apply('_codeaw/event', _event({'type': 'state', 'state': 'running', 'queued': 0, 'turnStartedAt': 1000, 'turnPromptId': 'p1'}));
    timeline.apply('_codeaw/event', _replies('k_1', ['好，提交', '先跑測試']));
    timeline.flush();
    await tester.pump();
    expect(find.text('好，提交'), findsNothing);
    timeline.apply('_codeaw/event', _event({
      'type': 'state', 'state': 'idle', 'queued': 0, 'stopReason': 'end_turn',
      'completedTurn': {'promptId': 'p1', 'startedAt': 1000, 'endedAt': 2000},
    }));
    timeline.flush();
    await tester.pump();
    expect(find.text('好，提交'), findsOneWidget);
    expect(find.text('先跑測試'), findsOneWidget);

    await tester.tap(find.text('先跑測試'));
    await tester.pump();
    expect(client.prompts, [
      [
        {'type': 'text', 'text': '先跑測試'},
      ],
    ]);
    expect(find.text('好，提交'), findsNothing);
    expect(timeline.items.whereType<MessageItem>().single.text, '先跑測試');
    await tester.pump(const Duration(seconds: 1));
  });

  test('shows an agent notice in the app, and reports whether it could', () {
    final client = _Client();
    addTearDown(client.dispose);
    final notifier = LocalNotifier((_) {});
    final shown = <(String, String, String)>[];
    notifier.watch(client, (id) => id == 'claude' ? 'Claude Code' : id, (_) => null);
    final notice = {'sessionId': 'claude:one', 'agentId': 'claude', 'message': 'Deploy needs you'};

    // Nothing can show it yet: the bridge must fall back to a push.
    expect(client.onNotice!(notice), isFalse);
    notifier.onForegroundNotice = (id, title, body) => shown.add((id, title, body));
    expect(client.onNotice!(notice), isTrue);
    expect(client.onNotice!({...notice, 'title': 'CI', 'agentName': 'Claude'}), isTrue);
    expect(shown, [('claude:one', 'Claude Code 有訊息給你', 'Deploy needs you'), ('claude:one', 'CI', 'Deploy needs you')]);
    expect(client.onNotice!({'sessionId': 'claude:one', 'message': ''}), isFalse);
    expect(client.onNotice!({'message': 'no chat'}), isFalse);
    // In the background without notification support (a browser tab) it is not shown.
    notifier.foreground = false;
    expect(client.onNotice!(notice), isFalse);
    expect(shown, hasLength(2));

    notifier.unwatch();
    expect(client.onNotice, isNull);
  });

  test('tells the bridge which chat is on screen, also after reconnecting', () {
    final client = _Client();
    addTearDown(client.dispose);
    client.setForeground(true, activeSessionId: 'claude:one');
    client.setForeground(true);
    client.setForeground(false, activeSessionId: 'claude:two');
    expect(client.states, [
      {'foreground': true, 'activeSessionId': 'claude:one', 'notices': true},
      {'foreground': true, 'notices': true},
      {'foreground': false, 'activeSessionId': 'claude:two', 'notices': true},
    ]);
  });
}
