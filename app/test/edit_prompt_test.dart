import 'package:codeaw/acp/jsonrpc.dart';
import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/session_controller.dart';
import 'package:codeaw/data/timeline.dart';
import 'package:codeaw/ui/chat/items.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class EditClient extends BridgeClient {
  EditClient()
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
    supportsPromptEditing = true;
  }
  final calls = <Map<String, dynamic>>[];
  final failures = <RpcError>[];

  @override
  Future<dynamic> request(String method, [Map<String, dynamic>? params]) async {
    calls.add({'method': method, ...?params});
    if (failures.isNotEmpty) throw failures.removeAt(0);
    if (params?['dryRun'] == true) return {'ok': true, 'newSession': false};
    return {
      'sessionId': 'codex:branch',
      'replaced': params?['replace'] == true,
      '_meta': {
        'codeaw': {'cwd': '/work'},
      },
    };
  }

  @override
  void notify(String method, [Map<String, dynamic>? params]) {}
}

const promptId = '0d4b3f86-6d0b-4bd4-9a35-6f2b6c3c7f51';

MessageItem sentPrompt(SessionController c, {bool image = true}) {
  for (final part in [
    {'type': 'text', 'text': 'fix '},
    {'type': 'resource_link', 'name': 'lib/a.dart', 'uri': 'file:///work/lib/a.dart'},
    if (image) {'type': 'image', 'mimeType': 'image/png', 'data': '', 'uri': 'codeaw-blob:${'a' * 64}'},
  ]) {
    c.timeline.apply('session/update', {
      'update': {
        'sessionUpdate': 'user_message_chunk',
        'content': part,
        '_meta': {
          'codeaw': {'mid': 'u-$promptId', 'promptId': promptId, 'queued': false},
        },
      },
    });
  }
  c.timeline.apply('_codeaw/event', {
    'event': {'type': 'prompt_receipt', 'promptId': promptId, 'status': 'read'},
  });
  c.timeline.flush();
  return c.timeline.items.whereType<MessageItem>().single;
}

void main() {
  test('only started, non-inserted prompts offer editing', () {
    MessageItem user() => MessageItem('k', MessageRole.user, 'm');
    expect(user().canEdit, isTrue, reason: 'imported native history has no prompt id');
    expect((user()..promptId = promptId).canEdit, isTrue);
    expect((user()..steered = true).canEdit, isFalse);
    expect((user()..optimistic = true).canEdit, isFalse);
    expect((user()..promptId = promptId..queued = true).canEdit, isFalse);
    expect((user()..promptId = promptId..queued = true..dequeued = 'started').canEdit, isTrue);
    expect((user()..promptId = promptId..dequeued = 'cancelled').canEdit, isFalse);
    expect((user()..removed = true).canEdit, isFalse);
    expect(MessageItem('k', MessageRole.agent, 'm').canEdit, isFalse);
  });

  test('editing fills the composer after the bridge check and restores the draft afterwards', () async {
    final client = EditClient();
    final c = SessionController(client, 'codex:test')
      ..attached = true
      ..draft = 'unsent @b.dart';
    c.draftMentions['b.dart'] = 'file:///work/b.dart';
    addTearDown(() {
      c.dispose();
      client.dispose();
    });
    final m = sentPrompt(c);
    expect(c.canEdit(m), isTrue);
    await c.startEdit(m);
    expect(client.calls.single, {'method': '_codeaw/session/fork', 'sessionId': 'codex:test', 'messageId': 'u-$promptId', 'dryRun': true});
    expect(c.editing, same(m));
    expect(c.draft, 'fix @lib/a.dart');
    expect(c.draftMentions, {'lib/a.dart': 'file:///work/lib/a.dart'});
    expect(c.editKeep.single['type'], 'image');

    // A dropped connection leaves the edit open; the retry reuses its prompt id.
    client.failures.add(RpcError(RpcError.connectionClosed, 'closed'));
    final blocks = [
      {'type': 'text', 'text': 'fix it properly'},
      ...c.editKeep,
    ];
    expect(await c.submitEdit(blocks, replace: true), isNull);
    expect(c.editing, same(m));
    final branch = await c.submitEdit(blocks, replace: true);
    expect(branch, (sessionId: 'codex:branch', cwd: '/work', replaced: true));
    final sends = client.calls.where((call) => call['prompt'] != null).toList();
    expect(sends, hasLength(2));
    expect(sends[0]['clientPromptId'], sends[1]['clientPromptId']);
    expect(sends[1], containsPair('replace', true));
    expect(sends[1]['prompt'], blocks);
    expect(c.editing, isNull);
    expect(c.draft, 'unsent @b.dart');
    expect(c.draftMentions, {'b.dart': 'file:///work/b.dart'});
  });

  test('a refused check explains the limitation and does not enter edit mode', () async {
    final client = EditClient();
    final c = SessionController(client, 'claude:test')..attached = true;
    addTearDown(() {
      c.dispose();
      client.dispose();
    });
    final toasts = <String>[];
    final sub = c.toasts.listen(toasts.add);
    addTearDown(sub.cancel);
    final m = sentPrompt(c);
    client.failures.add(RpcError(-32600, 'Kimi cannot branch from an earlier message; only the first message can be edited'));
    await c.startEdit(m);
    await Future<void>.delayed(Duration.zero);
    expect(c.editing, isNull);
    expect(toasts.single, contains('只能編輯第一則訊息'));
    client.supportsPromptEditing = false;
    expect(c.canEdit(m), isFalse, reason: 'older bridges have no fork method');
  });

  testWidgets('the edit button appears under sent prompts and opens edit mode', (tester) async {
    final client = EditClient();
    final c = SessionController(client, 'codex:test')..attached = true;
    addTearDown(() {
      c.dispose();
      client.dispose();
    });
    final m = sentPrompt(c, image: false);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: UserMessageView(m, controller: c)),
      ),
    );
    await tester.tap(find.byTooltip('編輯並從這裡重新開始'));
    await tester.pump();
    expect(c.editing, same(m));
    c.timeline.setTurnState('running', promptId: 'other');
    c.timeline.flush();
    c.cancelEdit();
    await tester.pump();
    expect(find.byTooltip('編輯並從這裡重新開始'), findsNothing, reason: 'a running chat cannot branch');
  });
}
