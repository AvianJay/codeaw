import 'dart:async';

import 'package:codeaw/acp/jsonrpc.dart';
import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/session_controller.dart';
import 'package:codeaw/data/timeline.dart';
import 'package:codeaw/ui/chat/items.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class RemovalClient extends BridgeClient {
  RemovalClient()
    : super(
        HostConfig(
          name: 'test',
          urls: ['ws://localhost/acp'],
          token: 'test',
          deviceId: 'test',
          deviceName: 'test',
        ),
      ) {
    status = ConnStatus.online;
  }
  final methods = <String>[];
  final turn = Completer<dynamic>();
  bool processing = false;
  bool oldBridge = false;
  @override
  Future<dynamic> request(String method, [Map<String, dynamic>? params]) async {
    methods.add(method);
    if (method == 'session/prompt') return turn.future;
    if (oldBridge) throw RpcError(RpcError.methodNotFound, 'Not supported');
    return {'removed': !processing, if (processing) 'reason': 'processing'};
  }

  @override
  void notify(String method, [Map<String, dynamic>? params]) =>
      methods.add(method);
}

const promptId = 'f7c7d369-aa03-45d4-bd6d-4e5fcad7c91c';
const removal = <String, dynamic>{
  'event': {
    'type': 'dequeued',
    'promptId': promptId,
    'cancelled': true,
    'removed': true,
  },
};

void main() {
  testWidgets(
    'clock and queued messages can be removed while the active turn and draft remain',
    (tester) async {
      final client = RemovalClient();
      final c = SessionController(client, 'codex:test')..draft = 'next draft';
      addTearDown(() {
        c.dispose();
        client.dispose();
      });
      for (final status in ['unknown', 'received']) {
        c.timeline.clear();
        c.timeline.addPendingPrompt(promptId, [
          {'type': 'text', 'text': 'stuck message'},
        ]);
        final m = c.timeline.items.whereType<MessageItem>().single
          ..receipt = status
          ..queued = status == 'received';
        c.timeline.setTurnState('running', promptId: 'active');
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListenableBuilder(
                listenable: c.timeline,
                builder: (_, _) => UserMessageView(m, controller: c),
              ),
            ),
          ),
        );
        expect(find.text('取消待送訊息'), findsOneWidget);
        await tester.tap(find.text('取消待送訊息'));
        await tester.pump();
        expect(
          c.timeline.items.whereType<MessageItem>().single.removed,
          isTrue,
        );
        expect(c.timeline.state, 'running');
        expect(c.draft, 'next draft');
        expect(client.methods.last, '_codeaw/session/remove_prompt');
        expect(client.methods, isNot(contains('session/cancel')));
        expect(find.text('stuck message'), findsNothing);
        await tester.pumpWidget(const SizedBox());
        c.timeline.clear();
      }
      await tester.pump(const Duration(seconds: 3));
    },
  );

  test(
    'a removal tombstone reconciles an uncertain local send in a full replay and cache',
    () {
      final t = Timeline()
        ..addPendingPrompt(promptId, [
          {'type': 'text', 'text': 'uncertain'},
        ]);
      final incoming = Timeline()..apply('_codeaw/event', removal);
      t.replaceWith(incoming);
      final m = t.items.whereType<MessageItem>().single;
      expect(m.removed, isTrue);
      expect(m.optimistic, isFalse);
      expect(m.canRemovePending, isFalse);
      final restored = Timeline.fromSnapshot(t.toSnapshot());
      expect(restored.items.whereType<MessageItem>().single.removed, isTrue);
      final fresh = Timeline()..apply('_codeaw/event', removal);
      restored.replaceWith(fresh);
      expect(restored.items.whereType<MessageItem>(), isEmpty);
    },
  );

  test(
    'accepted removal settles the send without restoring the composer draft',
    () async {
      final client = RemovalClient();
      final controller = SessionController(client, 'codex:test');
      addTearDown(() {
        controller.dispose();
        client.dispose();
      });
      final send = controller.send([
        {'type': 'text', 'text': 'queued'},
      ], queue: true);
      await Future<void>.delayed(Duration.zero);
      final m = controller.timeline.items.whereType<MessageItem>().single;
      expect(await controller.removePrompt(m), isTrue);
      expect(await send, isTrue);
      client.turn.complete({'stopReason': 'cancelled'});
    },
  );

  test(
    'a removed prompt in an older page stays hidden after caching and paging',
    () {
      final client = RemovalClient();
      final c = SessionController(client, 'codex:paged');
      addTearDown(() {
        c.dispose();
        client.dispose();
      });
      c.timeline.apply('_codeaw/event', removal);
      final restored = Timeline.fromSnapshot(c.timeline.toSnapshot());
      c.timeline.replaceWith(restored);
      final older = Timeline()
        ..apply('session/update', {
          'update': {
            'sessionUpdate': 'user_message_chunk',
            'content': {'type': 'text', 'text': 'old stuck queue'},
            '_meta': {
              'codeaw': {
                'mid': 'u-$promptId',
                'promptId': promptId,
                'queued': true,
              },
            },
          },
        });
      c.timeline.prependHistory(older);
      expect(c.timeline.items.whereType<MessageItem>().single.removed, isTrue);
      expect(chatTimelineItems(c).whereType<MessageItem>(), isEmpty);
    },
  );

  test(
    'processing and unsupported bridges keep the pending message without stopping any turn',
    () async {
      final client = RemovalClient();
      final controller = SessionController(client, 'codex:test');
      addTearDown(() {
        controller.dispose();
        client.dispose();
      });
      controller.timeline.addPendingPrompt(promptId, [
        {'type': 'text', 'text': 'keep'},
      ]);
      final m = controller.timeline.items.whereType<MessageItem>().single;
      client.processing = true;
      expect(await controller.removePrompt(m), isFalse);
      client.oldBridge = true;
      expect(await controller.removePrompt(m), isFalse);
      expect(m.removed, isFalse);
      expect(client.methods, isNot(contains('session/cancel')));
      m.receipt = 'read';
      expect(m.canRemovePending, isFalse);
      client.status = ConnStatus.offline;
      expect(await controller.removePrompt(m), isFalse);
    },
  );

  test(
    'an overlapping older page cannot restore a message removed from the loaded tail',
    () {
      Map<String, dynamic> update() => {
        'update': {
          'sessionUpdate': 'user_message_chunk',
          'content': {'type': 'text', 'text': 'stuck at page boundary'},
          '_meta': {
            'codeaw': {
              'mid': 'u-$promptId',
              'promptId': promptId,
              'queued': true,
            },
          },
        },
      };
      final timeline = Timeline()
        ..apply('session/update', update())
        ..apply('_codeaw/event', removal);
      final older = Timeline()..apply('session/update', update());
      timeline.prependHistory(older);
      final message = timeline.items.whereType<MessageItem>().single;
      expect(message.removed, isTrue);
      expect(message.dequeued, 'cancelled');
      expect(message.canRemovePending, isFalse);
    },
  );
}
