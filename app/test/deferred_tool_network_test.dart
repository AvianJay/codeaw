import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/session_controller.dart';
import 'package:codeaw/data/timeline.dart';
import 'package:codeaw/ui/chat/items.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class DetailClient extends BridgeClient {
  DetailClient()
    : super(
        HostConfig(
          name: 'PC',
          urls: ['ws://pc/acp'],
          token: 'test',
          deviceId: 'test',
          deviceName: 'Test',
        ),
      );
  int detailRequests = 0;
  @override
  Future<dynamic> request(String method, [Map<String, dynamic>? params]) async {
    if (method == '_codeaw/history/tool') {
      detailRequests++;
      return {
        'epoch': 'one',
        'seq': 4,
        'update': {
          'sessionUpdate': 'tool_call',
          'toolCallId': 'tool',
          'kind': 'edit',
          'status': 'completed',
          'rawInput': {'patch': 'the complete original patch'},
          'content': [
            {
              'type': 'diff',
              'path': 'test.txt',
              'oldText': 'before',
              'newText': 'after',
            },
          ],
        },
      };
    }
    throw StateError('Unexpected request $method');
  }
}

void main() {
  testWidgets(
    'deferred historical edits stay folded until tapped and then hydrate original input and diff',
    (tester) async {
      final client = DetailClient();
      final controller = SessionController(client, 'codex:test')..epoch = 'one';
      controller.onMessage(
        SessionMessage('session/update', {
          'update': {
            'sessionUpdate': 'tool_call',
            'toolCallId': 'tool',
            'title': '歷史修改',
            'kind': 'edit',
            'status': 'completed',
            '_meta': {
              'codeaw': {
                'deferredTool': {'seq': 4, 'bytes': 8000, 'hasDiff': true},
              },
            },
          },
          '_meta': {
            'codeaw': {'seq': 4},
          },
        }),
      );
      final tool = controller.timeline.items.whereType<ToolItem>().single;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TimelineItemView(
              item: tool,
              controller: controller,
              isLast: false,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(client.detailRequests, 0);
      expect(find.text('讀取完整輸出'), findsNothing);
      await tester.tap(find.text('歷史修改'));
      await tester.pumpAndSettle();
      expect(client.detailRequests, 1);
      expect(tool.detailsDeferred, isFalse);
      expect(tool.rawInput, {'patch': 'the complete original patch'});
      expect(tool.content!.single['newText'], 'after');
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      client.dispose();
    },
  );
}
