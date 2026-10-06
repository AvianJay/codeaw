import 'package:codeaw/app_state.dart';
import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/history_cache.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/session_controller.dart';
import 'package:codeaw/data/timeline.dart';
import 'package:codeaw/ui/common/markdown_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _host = HostConfig(name: 'PC', urls: ['ws://pc/acp'], token: 'token', deviceId: 'A', deviceName: 'phone');

class _Storage implements HistoryStorage {
  final values = <String, Map<String, dynamic>>{};
  @override
  Future<Map<String, dynamic>?> read(String host, String session) async => values['$host/$session'];
  @override
  Future<void> write(String host, String session, Map<String, dynamic> value) async => values['$host/$session'] = value;
  @override
  Future<void> remove(String host, String session) async => values.remove('$host/$session');
  @override
  Future<void> clear(String host) async => values.clear();
}

class _Client extends BridgeClient {
  _Client() : super(_host) {
    status = ConnStatus.online;
  }
  final requests = <String, Map<String, dynamic>?>{};
  Future<dynamic> Function(String, Map<String, dynamic>?)? handle;

  @override
  Future<dynamic> request(String method, [Map<String, dynamic>? params]) {
    requests[method] = params;
    return handle!(method, params);
  }
}

Map<String, dynamic> _prompt(String id) => {
  'sessionUpdate': 'user_message_chunk',
  'content': {'type': 'text', 'text': 'prompt $id'},
  '_meta': {
    'codeaw': {'mid': 'u-$id', 'promptId': id},
  },
};
Map<String, dynamic> _reply(String mid, String text) => {
  'sessionUpdate': 'agent_message_chunk',
  'content': {'type': 'text', 'text': text},
  '_meta': {
    'codeaw': {'mid': mid},
  },
};
Map<String, dynamic> _state(String state, String promptId, int startedAt, [int? endedAt]) => {
  'type': 'state',
  'state': state,
  'queued': 0,
  if (state != 'idle') ...{'turnStartedAt': startedAt, 'turnPromptId': promptId},
  if (endedAt != null) ...{
    'stopReason': 'end_turn',
    'completedTurn': {'promptId': promptId, 'startedAt': startedAt, 'endedAt': endedAt},
  },
};

void _send(SessionController c, String method, int seq, Map<String, dynamic> body) => c.onMessage(
  SessionMessage(method, {
    'sessionId': c.sessionId,
    ...body,
    '_meta': {
      'codeaw': {'seq': seq, 't': seq * 1000},
    },
  }),
);
void _update(SessionController c, int seq, Map<String, dynamic> u) => _send(c, 'session/update', seq, {'update': u});
void _event(SessionController c, int seq, Map<String, dynamic> e) => _send(c, '_codeaw/event', seq, {'event': e});

void _page(SessionController c, int requested, List<Map<String, dynamic>> entries, {int? before}) => c.onMessage(
  SessionMessage('_codeaw/history/page', {
    'sessionId': c.sessionId,
    'epoch': 'one',
    'requested': requested,
    'before': ?before,
    'entries': entries,
  }),
);

List<String> _keys(Timeline t) => t.items.map((i) => i.key).toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loads the newest page first, then merges older pages before it and keeps the cursor cached', () async {
    final client = _Client();
    final storage = _Storage();
    final cache = HistoryCache(client.host, storage: storage);
    final c = SessionController(client, 'codex:paged', cache: cache);
    client.handle = (method, params) async {
      expect(method, 'session/load');
      expect(params!['_meta']['codeaw'], containsPair('pageBytes', historyPageBytes));
      expect(params['_meta']['codeaw'], isNot(contains('lazyHistoryBytes')));
      c.onMessage(SessionMessage('_codeaw/replay', {'sessionId': c.sessionId, 'mode': 'full', 'epoch': 'one', 'lastSeq': 20, 'before': 10}));
      _update(c, 10, _prompt('p2'));
      _event(c, 11, _state('running', 'p2', 11000));
      _update(c, 12, _reply('a2', 'two'));
      // The first prompt's read receipt landed after the page boundary.
      _event(c, 13, {'type': 'prompt_receipt', 'promptId': 'p1', 'status': 'read'});
      _event(c, 14, {'type': 'error', 'message': 'newer error'});
      _event(c, 15, _state('idle', 'p2', 11000, 15000));
      return {
        '_meta': {
          'codeaw': {'epoch': 'one', 'lastSeq': 20, 'state': 'idle'},
        },
      };
    };
    await c.attach();
    expect(c.olderBefore, 10);
    expect(_keys(c.timeline), ['user_message_chunk:u-p2', 'agent_message_chunk:a2', 'error:0', 'turn:p2']);

    // The old reply keeps streaming; the bridge folds it into the page sent later.
    _update(c, 21, _reply('a1', ' more'));
    expect(c.timeline.items.last.key, 'agent_message_chunk:a1');

    client.handle = (method, params) async {
      expect(method, '_codeaw/history/page');
      expect(params, {'sessionId': c.sessionId, 'epoch': 'one', 'before': 10, 'pageBytes': historyPageBytes});
      expect(c.loadingOlder, isTrue);
      _page(c, 10, [
        {'seq': 1, 't': 1000, 'update': _prompt('p1')},
        {'seq': 2, 't': 2000, 'event': _state('running', 'p1', 2000)},
        {'seq': 21, 't': 3000, 'update': _reply('a1', 'one more')},
        {'seq': 4, 't': 4000, 'event': {'type': 'error', 'message': 'older error'}},
        {'seq': 5, 't': 5000, 'event': _state('idle', 'p1', 2000, 5000)},
      ], before: 1);
      return <String, dynamic>{};
    };
    await c.loadOlder();
    expect(c.loadingOlder, isFalse);
    expect(c.olderBefore, 1);
    expect(_keys(c.timeline), [
      'user_message_chunk:u-p1',
      'agent_message_chunk:a1',
      'error:p10:0',
      'turn:p1',
      'user_message_chunk:u-p2',
      'agent_message_chunk:a2',
      'error:0',
      'turn:p2',
    ]);
    final messages = c.timeline.items.whereType<MessageItem>().toList();
    expect(messages[1].text, 'one more');
    expect(messages.first.receipt, 'read');
    expect(c.timeline.items.whereType<TurnSummaryItem>().first.responseText, 'one more');
    // Live updates continue on the merged item.
    _update(c, 22, _reply('a1', '!'));
    expect(messages[1].text, 'one more!');
    expect(c.timeline.rootItems, c.timeline.items);

    await c.persist();
    c.dispose();
    final restored = SessionController(client, 'codex:paged', cache: cache);
    await restored.restore();
    expect(restored.olderBefore, 1);
    expect(_keys(restored.timeline), _keys(c.timeline));
    restored.dispose();
    client.dispose();
  });

  test('a page from another epoch, another cursor or during a rebuild is ignored', () async {
    final client = _Client();
    final c = SessionController(client, 'codex:paged', cache: HistoryCache(client.host, storage: _Storage()));
    client.handle = (method, params) async {
      c.onMessage(SessionMessage('_codeaw/replay', {'sessionId': c.sessionId, 'mode': 'full', 'epoch': 'one', 'lastSeq': 3, 'before': 2}));
      _update(c, 3, _reply('new', 'new'));
      return {
        '_meta': {
          'codeaw': {'epoch': 'one', 'lastSeq': 3, 'state': 'idle'},
        },
      };
    };
    await c.attach();
    _page(c, 5, [
      {'seq': 1, 't': 1, 'update': _reply('old', 'old')},
    ]);
    c.epoch = 'two';
    _page(c, 2, [
      {'seq': 1, 't': 1, 'update': _reply('old', 'old')},
    ]);
    expect(_keys(c.timeline), ['agent_message_chunk:new']);
    expect(c.olderBefore, 2);
    c.dispose();
    client.dispose();
  });

  test('a turn split across pages keeps one summary with its prompt and all replies', () {
    final live = Timeline();
    void apply(Timeline t, String method, int seq, Map<String, dynamic> body) => t.apply(method, {
      ...body,
      '_meta': {
        'codeaw': {'seq': seq, 't': seq * 1000},
      },
    });
    // The newest page starts mid-turn with the active state the bridge puts first.
    apply(live, '_codeaw/event', 2, {'event': _state('running', 'p', 2000)});
    apply(live, 'session/update', 6, {'update': _reply('late', 'late reply')});
    live.flush();
    expect(live.currentTurn!.prompt, isNull);
    final older = Timeline(anonScope: 'p5:');
    apply(older, 'session/update', 1, {'update': _prompt('p')});
    apply(older, '_codeaw/event', 2, {'event': _state('running', 'p', 2000)});
    apply(older, 'session/update', 3, {'update': _reply('early', 'early reply')});
    live.prependHistory(older);
    expect(_keys(live), ['user_message_chunk:u-p', 'agent_message_chunk:early', 'agent_message_chunk:late']);
    expect(live.currentTurn!.prompt!.key, 'user_message_chunk:u-p');
    expect(live.currentTurn!.responseText, 'early reply\n\nlate reply');
    apply(live, '_codeaw/event', 7, {'event': _state('idle', 'p', 2000, 7000)});
    live.flush();
    final turn = live.items.whereType<TurnSummaryItem>().single;
    expect(turn.prompt!.key, 'user_message_chunk:u-p');
    expect(turn.responseText, 'early reply\n\nlate reply');
  });

  test('data saver asks for smaller pages and defers smaller tool output', () async {
    final client = _Client();
    var saver = true;
    final hub = SessionHub(client, cache: HistoryCache(client.host, storage: _Storage()), dataSaver: () => saver);
    client.handle = (method, params) async => {
      '_meta': {
        'codeaw': {'epoch': 'one', 'lastSeq': 0, 'state': 'idle'},
      },
    };
    final c = hub.open('codex:saver');
    await c.attach();
    expect(client.requests['session/load']!['_meta']['codeaw'], allOf(
      containsPair('pageBytes', dataSaverPageBytes),
      containsPair('lazyHistoryBytes', dataSaverToolBytes),
      containsPair('lazyHistory', true),
    ));
    saver = false;
    c.olderBefore = 9;
    await c.loadOlder();
    expect(client.requests['_codeaw/history/page']!['pageBytes'], historyPageBytes);
    hub.dispose();
    client.dispose();
  });

  testWidgets('data saver shows downloaded images only after a tap', (tester) async {
    final state = AppState(HostStore(), openSession: (_) {})..dataSaver = true;
    final provider = NetworkImage('http://pc/api/blobs/${'b' * 64}');
    await tester.pumpWidget(AppScope(
      state: state,
      child: MaterialApp(
        home: Scaffold(
          body: DeferredImage(provider: provider, builder: (_) => const Text('image shown')),
        ),
      ),
    ));
    expect(find.text('image shown'), findsNothing);
    await tester.tap(find.text('點擊載入圖片'));
    await tester.pump();
    expect(find.text('image shown'), findsOneWidget);
    state.dataSaver = false;
    await tester.pumpWidget(AppScope(
      state: state,
      child: MaterialApp(
        home: Scaffold(
          body: DeferredImage(key: UniqueKey(), provider: provider, builder: (_) => const Text('image shown')),
        ),
      ),
    ));
    expect(find.text('image shown'), findsOneWidget);
  });
}
