import 'dart:async';

import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/session_controller.dart';
import 'package:codeaw/data/timeline.dart';
import 'package:codeaw/ui/chat/items.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:codeaw/acp/jsonrpc.dart';

class ReceiptClient extends BridgeClient {
  ReceiptClient()
    : super(
        HostConfig(
          name: 'fixture',
          urls: ['ws://localhost/acp'],
          token: 'fixture',
          deviceId: 'fixture',
          deviceName: 'fixture',
        ),
      );
  final reply = Completer<dynamic>();
  Map<String, dynamic>? prompt;
  @override
  Future<dynamic> request(String method, [Map<String, dynamic>? params]) {
    prompt = params;
    return reply.future;
  }
}

void main() {
  test('native replay retains a user message containing both text and image', () {
    final t = Timeline();
    for (final (index, content) in [
      (0, {'type': 'text', 'text': 'Image caption'}),
      (1, {'type': 'image', 'uri': 'codeaw-blob:test', 'data': ''}),
    ]) {
      t.apply('session/update', {'update': {
        'sessionUpdate': 'user_message_chunk', 'content': content,
        '_meta': {'codeaw': {'promptId': 'p', 'mid': 'u-p', 'replace': true,
          'partIndex': index, 'receipt': 'read'}},
      }});
    }
    final m = t.items.whereType<MessageItem>().single;
    expect(m.text, 'Image caption');
    expect(m.parts.map((p) => p['type']), ['text', 'image']);
    expect(m.receipt, 'read');
  });
  test('legacy orphan receipts do not create empty user bubbles', () {
    final t = Timeline();
    t.apply('_codeaw/event', {
      'event': {
        'type': 'prompt_receipt',
        'promptId': 'missing',
        'status': 'read',
      },
    });
    expect(t.items, isEmpty);
  });
  test(
    'late prompt errors after disposal do not notify a disposed timeline',
    () async {
      final client = ReceiptClient();
      final c = SessionController(client, 'codex:test');
      final sending = c.send([
        {'type': 'text', 'text': 'test'},
      ]);
      c.dispose();
      client.reply.completeError(RpcError(-32602, 'late error'));
      expect(await sending, isTrue);
      client.dispose();
    },
  );

  test(
    'full replay keeps authoritative order and unconfirmed sends at the bottom',
    () {
      final t = Timeline();
      t.addPendingPrompt('p1', [
        {'type': 'text', 'text': 'confirmed'},
      ]);
      t.addPendingPrompt('p2', [
        {'type': 'text', 'text': 'uncertain'},
      ]);
      t.clear(preserveUnconfirmed: true);
      for (final (text, id) in [('old history', null), ('confirmed', 'p1')]) {
        t.apply('session/update', {
          'update': {
            'sessionUpdate': 'user_message_chunk',
            'content': {'type': 'text', 'text': text},
            '_meta': {
              'codeaw': {'mid': id ?? 'old', 'promptId': id},
            },
          },
        });
      }
      t.finishReplay();
      expect(t.items.whereType<MessageItem>().map((m) => m.text), [
        'old history',
        'confirmed',
        'uncertain',
      ]);
    },
  );
  test(
    'bridge receipt resolves send before the queued turn completes',
    () async {
      final client = ReceiptClient();
      final c = SessionController(client, 'codex:test');
      addTearDown(() {
        c.dispose();
        client.dispose();
      });
      var completed = false;
      final send = c
          .send([
            {'type': 'text', 'text': 'queued text'},
          ], queue: true)
          .then((value) {
            completed = true;
            return value;
          });
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      final id = client.prompt!['_meta']['codeaw']['clientPromptId'] as String;
      expect(client.prompt!['_meta']['codeaw']['delivery'], 'queue');
      c.onMessage(
        SessionMessage('_codeaw/event', {
          'event': {
            'type': 'prompt_receipt',
            'promptId': id,
            'status': 'received',
          },
        }),
      );
      expect(await send, isTrue);
      expect(client.reply.isCompleted, isFalse);
      client.reply.complete({'stopReason': 'end_turn'});
    },
  );

  test(
    'unconfirmed text survives full replay then merges into one authoritative message',
    () {
      final t = Timeline();
      t.addPendingPrompt('p1', [
        {'type': 'text', 'text': 'keep this once'},
      ]);
      t.clear(preserveUnconfirmed: true);
      t.apply('_codeaw/event', {
        'event': {
          'type': 'prompt_receipt',
          'promptId': 'p1',
          'status': 'received',
        },
      });
      t.apply('session/update', {
        'update': {
          'sessionUpdate': 'user_message_chunk',
          'content': {'type': 'text', 'text': 'keep this once'},
          '_meta': {
            'codeaw': {'mid': 'u-p1', 'promptId': 'p1', 'queued': true},
          },
        },
      });
      final item = t.items.whereType<MessageItem>().single;
      expect(item.text, 'keep this once');
      expect(item.receipt, 'received');
      expect(item.optimistic, isFalse);
      t.apply('_codeaw/event', {
        'event': {'type': 'prompt_receipt', 'promptId': 'p1', 'status': 'read'},
      });
      t.apply('_codeaw/event', {
        'event': {
          'type': 'prompt_receipt',
          'promptId': 'p1',
          'status': 'received',
        },
      });
      expect(item.receipt, 'read');
      expect(item.dequeued, 'started');
    },
  );

  testWidgets(
    'ticks only represent confirmed delivery, including replay and cancellation',
    (tester) async {
      final m = MessageItem('user:test', MessageRole.user, 'test')
        ..parts.add({'type': 'text', 'text': 'Test message'});
      for (final (status, icon, label) in [
        ('sending', Icons.schedule_rounded, '傳送中'),
        ('unknown', Icons.schedule_rounded, '送達結果未知，請確認聊天紀錄後再重試'),
        ('received', Icons.check_rounded, '伺服器已收到'),
        ('read', Icons.done_all_rounded, 'AI 已開始處理'),
        ('failed', Icons.error_outline_rounded, '處理失敗，請查看錯誤'),
      ]) {
        m.receipt = status;
        await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: UserMessageView(m))),
        );
        expect(find.byTooltip(label), findsOneWidget);
        expect(find.byIcon(icon), findsOneWidget);
        if (status != 'read') {
          expect(find.byIcon(Icons.done_all_rounded), findsNothing);
        }
        if (status != 'received') {
          expect(find.byIcon(Icons.check_rounded), findsNothing);
        }
        expect(tester.takeException(), isNull);
      }
    },
  );
}
