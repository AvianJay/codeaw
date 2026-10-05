import 'package:codeaw/acp/jsonrpc.dart';
import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/mentions.dart';
import 'package:codeaw/data/models.dart';
import 'package:codeaw/data/session_controller.dart';
import 'package:codeaw/data/timeline.dart';
import 'package:codeaw/ui/chat/composer.dart';
import 'package:codeaw/ui/chat/items.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _root = '/work/app';
const _tree = [
  ('lib', 'dir'),
  ('lib/ui', 'dir'),
  ('lib/ui/chat', 'dir'),
  ('lib/ui/chat/composer.dart', 'file'),
  ('lib/ui/chat/chat_page.dart', 'file'),
  ('lib/ui/common', 'dir'),
  ('README.md', 'file'),
];

class _Client extends BridgeClient {
  _Client({this.search = true})
    : super(HostConfig(name: 'fixture', urls: ['ws://localhost/acp'], token: 'fixture', deviceId: 'fixture', deviceName: 'fixture')) {
    status = ConnStatus.online;
    agents = [AgentInfo(id: 'claude', name: 'Claude Code', status: 'ready', image: true)];
  }

  /// Older bridges have no `_codeaw/fs/search`.
  final bool search;
  final prompts = <List<dynamic>>[];
  final methods = <String>[];

  @override
  Future<dynamic> request(String method, [Map<String, dynamic>? params]) async {
    methods.add(method);
    switch (method) {
      case 'session/prompt':
        prompts.add(params!['prompt'] as List);
      case '_codeaw/fs/search':
        if (!search) throw RpcError(RpcError.methodNotFound, 'Method not found');
        final query = '${params!['query']}'.toLowerCase();
        return {
          'files': [
            for (final (rel, type) in _tree)
              if (rel.toLowerCase().contains(query)) {'path': '$_root/$rel', 'relative': rel, 'type': type},
          ],
        };
      case '_codeaw/fs/list':
        final dir = '${params!['path']}';
        return {
          'path': dir,
          'entries': [
            for (final (rel, type) in _tree)
              if ('$_root/$rel'.substring(0, '$_root/$rel'.lastIndexOf('/')) == dir)
                {'name': rel.split('/').last, 'path': '$_root/$rel', 'type': type},
          ],
        };
    }
    return {};
  }
}

Finder get _input => find.descendant(of: find.byType(Composer), matching: find.byType(TextField));

String _text(WidgetTester tester) => tester.widget<TextField>(_input).controller!.text;

Future<({SessionController controller, _Client client})> _show(WidgetTester tester, {bool search = true, Size size = const Size(430, 900)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final client = _Client(search: search);
  final controller = SessionController(client, 'claude:one', cwd: _root);
  addTearDown(() {
    controller.dispose();
    client.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Column(children: [const Spacer(), Composer(controller: controller)]),
      ),
    ),
  );
  return (controller: controller, client: client);
}

/// Lets the debounced file search run and its answer arrive.
Future<void> _search(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump();
}

void main() {
  test('finds mentions as words, longest token first, CJK text included', () {
    const tokens = ['lib/main.dart', 'lib/'];
    expect(mentionRanges('看@lib/main.dart的錯誤', tokens), [(start: 1, end: 15, token: 'lib/main.dart')]);
    expect(mentionRanges('see @lib/main.dart.', tokens).single.token, 'lib/main.dart');
    expect(mentionRanges('me@lib/main.dart', tokens), isEmpty);
    expect(mentionRanges('@lib/main.dartx', tokens), isEmpty);
    expect(mentionRanges('@lib/ and @lib/main.dart', tokens).map((r) => r.token), ['lib/', 'lib/main.dart']);
    expect(
      promptBlocks('看 @lib/main.dart 的錯誤', {'lib/main.dart': 'file:///work/app/lib/main.dart'}),
      [
        {'type': 'text', 'text': '看 '},
        {'type': 'resource_link', 'name': 'lib/main.dart', 'uri': 'file:///work/app/lib/main.dart'},
        {'type': 'text', 'text': ' 的錯誤'},
      ],
    );
    expect(promptBlocks('no mentions', const {}), [
      {'type': 'text', 'text': 'no mentions'},
    ]);
    expect(fileUriOf(r'D:\proj\my app\main.dart'), 'file:///D:/proj/my%20app/main.dart');
    expect(fileUriOf('/home/me/app/main.dart'), 'file:///home/me/app/main.dart');
  });

  test('reusing a prompt restores its mentions', () {
    final c = SessionController(_Client(), 'claude:one', cwd: _root);
    addTearDown(c.dispose);
    final prompt = MessageItem('u', MessageRole.user, 'u')
      ..parts.addAll([
        {'type': 'text', 'text': '看 '},
        {'type': 'resource_link', 'name': 'lib/main.dart', 'uri': 'file:///work/app/lib/main.dart'},
        {'type': 'text', 'text': ' 的錯誤'},
      ]);
    expect(prompt.text, '看  的錯誤');
    c.reusePrompt(prompt);
    expect(c.draft, '看 @lib/main.dart 的錯誤');
    expect(c.draftMentions, {'lib/main.dart': 'file:///work/app/lib/main.dart'});
  });

  testWidgets('the attach menu floats above the button and offers more than images', (tester) async {
    await _show(tester);
    await tester.tap(find.byTooltip('附加'));
    await tester.pumpAndSettle();
    final button = tester.getRect(find.byTooltip('附加'));
    final field = tester.getRect(_input);
    for (final label in ['從相簿選擇', '貼上剪貼簿圖片', '提及檔案']) {
      final item = tester.getRect(find.text(label));
      expect(item.bottom, lessThanOrEqualTo(button.top), reason: label);
      expect(item.bottom, lessThanOrEqualTo(field.top), reason: label);
    }
    // Opening the menu does not move the composer.
    expect(tester.getRect(_input), field);
    await tester.tap(find.text('提及檔案'));
    await tester.pumpAndSettle();
    expect(find.text('提及檔案'), findsNothing);
    expect(_text(tester), '@');
    await _search(tester);
    expect(find.text('lib/'), findsOneWidget);
    expect(find.text('README.md', skipOffstage: false), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping outside closes the attach menu; the button toggles it', (tester) async {
    await _show(tester);
    await tester.tap(find.byTooltip('附加'));
    await tester.pumpAndSettle();
    expect(find.text('提及檔案'), findsOneWidget);
    await tester.tap(find.byTooltip('附加'));
    await tester.pumpAndSettle();
    expect(find.text('提及檔案'), findsNothing);
    await tester.tap(find.byTooltip('附加'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(200, 100));
    await tester.pumpAndSettle();
    expect(find.text('提及檔案'), findsNothing);
  });

  testWidgets('@ completes files and sends them as resource links in place', (tester) async {
    final h = await _show(tester);
    await tester.enterText(_input, '看 @comp');
    await _search(tester);
    expect(find.text('composer.dart'), findsOneWidget);
    expect(find.text('lib/ui/chat'), findsOneWidget);
    await tester.tap(find.text('composer.dart'));
    await tester.pump();
    expect(_text(tester), '看 @lib/ui/chat/composer.dart ');
    expect(find.text('composer.dart'), findsNothing);
    await tester.enterText(_input, '看 @lib/ui/chat/composer.dart 的錯誤');
    await tester.tap(find.byTooltip('送出'));
    await tester.pump();
    expect(h.client.prompts.single, [
      {'type': 'text', 'text': '看 '},
      {'type': 'resource_link', 'name': 'lib/ui/chat/composer.dart', 'uri': 'file:///work/app/lib/ui/chat/composer.dart'},
      {'type': 'text', 'text': ' 的錯誤'},
    ]);
    expect(h.controller.draftMentions, isEmpty);
    expect(_text(tester), isEmpty);
  });

  testWidgets('folders open for completion or can be mentioned themselves', (tester) async {
    final h = await _show(tester);
    await tester.enterText(_input, '@cha');
    await _search(tester);
    await tester.tap(find.text('chat/'));
    await _search(tester);
    expect(_text(tester), '@lib/ui/chat/');
    expect(find.text('chat_page.dart'), findsOneWidget);
    await tester.enterText(_input, '@chat');
    await _search(tester);
    await tester.tap(find.byTooltip('提及這個資料夾').first);
    await tester.pump();
    expect(_text(tester), '@lib/ui/chat/ ');
    expect(h.controller.draftMentions, {'lib/ui/chat/': 'file:///work/app/lib/ui/chat'});
  });

  testWidgets('arrow keys pick a suggestion and Escape hides the list', (tester) async {
    await _show(tester, size: const Size(1000, 900));
    await tester.tap(_input);
    await tester.enterText(_input, '@chat');
    await _search(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(_text(tester), '@lib/ui/chat/chat_page.dart ');
    await tester.enterText(_input, '@lib/ui/chat/chat_page.dart @READ');
    await _search(tester);
    expect(find.text('README.md'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('README.md'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('older bridges complete one folder at a time', (tester) async {
    final h = await _show(tester, search: false);
    await tester.enterText(_input, '@lib/ui/c');
    await _search(tester);
    expect(find.text('chat/'), findsOneWidget);
    expect(find.text('common/'), findsOneWidget);
    await tester.tap(find.text('chat/'));
    await _search(tester);
    expect(find.text('composer.dart'), findsOneWidget);
    expect(h.client.methods.where((m) => m == '_codeaw/fs/search'), hasLength(1));
  });

  testWidgets('sent mentions read inline in the user bubble', (tester) async {
    final c = SessionController(_Client(), 'claude:one', cwd: _root);
    addTearDown(c.dispose);
    for (final content in [
      {'type': 'text', 'text': '看 '},
      {'type': 'resource_link', 'name': 'lib/ui/chat/composer.dart', 'uri': 'file:///work/app/lib/ui/chat/composer.dart'},
      {'type': 'text', 'text': ' 的錯誤'},
    ]) {
      c.timeline.apply('session/update', {
        'update': {
          'sessionUpdate': 'user_message_chunk',
          'content': content,
          '_meta': {'codeaw': {'mid': 'u-p1', 'promptId': 'p1'}},
        },
      });
    }
    c.timeline.flush();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TimelineItemView(item: c.timeline.rootItems.single, controller: c, isLast: true),
        ),
      ),
    );
    expect(find.byType(MentionChip), findsOneWidget);
    expect(find.text('composer.dart'), findsOneWidget);
    expect(find.textContaining('看'), findsOneWidget);
    expect((c.timeline.rootItems.single as MessageItem).promptText, '看 @lib/ui/chat/composer.dart 的錯誤');
    expect(tester.takeException(), isNull);
  });
}
