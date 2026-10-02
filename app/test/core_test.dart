import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codeaw/acp/jsonrpc.dart';
import 'package:codeaw/data/timeline.dart';
import 'package:codeaw/util/diff.dart';
import 'package:flutter_test/flutter_test.dart';

Timeline reduceAll(List<dynamic> messages) {
  final t = Timeline();
  for (final m in messages.cast<Map<String, dynamic>>()) {
    t.apply(m['method'] as String, Map<String, dynamic>.from(m['params'] as Map));
  }
  t.flush();
  return t;
}

void main() {
  group('timeline', () {
    final fixture = jsonDecode(File('test/fixtures/replay.json').readAsStringSync()) as Map<String, dynamic>;

    test('compacted replay reduces to the same timeline as the raw log', () {
      final raw = reduceAll(fixture['raw'] as List);
      final compacted = reduceAll(fixture['compacted'] as List);
      expect(compacted.debugSnapshot(), equals(raw.debugSnapshot()));
      expect((fixture['compacted'] as List).length, lessThan((fixture['raw'] as List).length));
    });

    test('folds tool calls, permissions and queued prompts', () {
      final t = reduceAll(fixture['raw'] as List);
      final tool = t.items.whereType<ToolItem>().firstWhere((i) => i.toolCallId == 't1');
      expect(tool.terminalOutput, 'line1\nline2\n');
      expect(tool.exitCode, 0);
      expect(tool.status, 'completed');
      final edit = t.items.whereType<ToolItem>().firstWhere((i) => i.toolCallId == 'e1');
      expect(edit.content!.map((c) => c['type']), ['diff', 'content']);
      final perm = t.items.whereType<PermissionItem>().single;
      expect(perm.optionName, 'Allow');
      expect(perm.by, 'A');
      expect(t.items.whereType<ElicitationItem>().single.action, 'accept');
      final queued = t.items.whereType<MessageItem>().firstWhere((m) => m.text == 'echo queued one');
      expect(queued.queued, isTrue);
      expect(queued.dequeued, 'started');
      expect(t.items.whereType<StopItem>().single.stopReason, 'cancelled');
      expect(t.title, 'Fixture Session');
      expect(t.state, 'idle');
      final agentText = t.items.whereType<MessageItem>().where((m) => m.role == MessageRole.agent).map((m) => m.text).toList();
      expect(agentText.first, 'hello streaming world');
    });

    test('notifies only items that changed', () {
      final t = Timeline();
      var listChanges = 0;
      t.addListener(() => listChanges++);
      void chunk(String text) => t.apply('session/update', {
            'update': {
              'sessionUpdate': 'agent_message_chunk',
              'content': {'type': 'text', 'text': text},
              '_meta': {'codeaw': {'mid': 'm1'}},
            },
          });
      chunk('a');
      t.flush();
      final item = t.items.single as MessageItem;
      var itemChanges = 0;
      item.addListener(() => itemChanges++);
      chunk('b');
      chunk('c');
      t.flush();
      expect(item.text, 'abc');
      expect(itemChanges, 1);
      expect(listChanges, 1);
    });
  });

  group('jsonrpc', () {
    test('correlates requests, serves incoming requests and honours cancel_request', () async {
      final aOut = StreamController<String>();
      final bOut = StreamController<String>();
      late JsonRpcPeer a, b;
      CancelToken? seenToken;
      final gotNotification = Completer<String>();
      a = JsonRpcPeer(
        send: aOut.add,
        onRequest: (m, p, t) async => {'echo': p['x']},
        onNotification: (m, p) => gotNotification.complete(m),
      );
      b = JsonRpcPeer(
        send: bOut.add,
        onRequest: (m, p, t) async {
          seenToken = t;
          await t.whenCancelled;
          return {'cancelled': true};
        },
        onNotification: (m, p) {},
      );
      aOut.stream.listen(b.handle);
      bOut.stream.listen(a.handle);

      expect(await b.request('ping', {'x': 1}), {'echo': 1});
      b.notify('hello');
      expect(await gotNotification.future, 'hello');

      final pending = a.request('slow');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      // The peer withdraws request id 1 (the first one `a` sent).
      b.handle(jsonEncode({'jsonrpc': '2.0', 'method': r'$/cancel_request', 'params': {'requestId': 1}}));
      expect(seenToken!.isCancelled, isTrue);
      expect(await pending, {'cancelled': true});

      final failing = a.request('never');
      a.close();
      expect(failing, throwsA(isA<RpcError>()));
    });
  });

  group('diff', () {
    test('line diff produces unified hunks', () {
      final lines = lineDiff('a\nb\nc\nd\n', 'a\nB\nc\nd\ne\n', context: 1);
      final rendered = lines.map((l) => switch (l.kind) {
            DiffKind.add => '+${l.text}',
            DiffKind.remove => '-${l.text}',
            DiffKind.context => ' ${l.text}',
            _ => l.text,
          });
      expect(rendered.join('|'), '@@ -1,4 +1,5 @@| a|-b|+B| c| d|+e');
      expect(lineDiff('same', 'same'), isEmpty);
      expect(lineDiff(null, 'x\ny').where((l) => l.kind == DiffKind.add).length, 2);
    });

    test('parses git diff output', () {
      const text = 'diff --git a/src/a.ts b/src/a.ts\nindex 1..2 100644\n--- a/src/a.ts\n+++ b/src/a.ts\n@@ -10,3 +10,3 @@ fn\n ctx\n-foo()\n+bar()\n ctx\n';
      final files = parseUnifiedDiff(text);
      expect(files.single.path, 'src/a.ts');
      expect(files.single.added, 1);
      expect(files.single.removed, 1);
      final add = files.single.lines.firstWhere((l) => l.kind == DiffKind.add);
      expect(add.newNo, 11);
    });
  });
}
