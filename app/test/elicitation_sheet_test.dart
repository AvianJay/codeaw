import 'package:codeaw/acp/jsonrpc.dart';
import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/session_controller.dart';
import 'package:codeaw/ui/chat/elicitation_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Controller extends SessionController {
  _Controller(BridgeClient client) : super(client, 'codex:question-test');
  String? action;
  Map<String, dynamic>? answer;
  @override
  void answerElicitation(
    PendingRequest req,
    String action, [
    Map<String, dynamic>? content,
  ]) {
    this.action = action;
    answer = content;
  }
}

const _choice = {
  'type': 'string',
  'title': '選擇或自訂',
  'default': 'A',
  'enum': ['A', 'B'],
  '_meta': {
    'codeaw': {'allowCustom': true},
  },
};

Future<(_Controller, PendingRequest)> _open(
  WidgetTester tester,
  Map<String, dynamic> props, {
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final client = BridgeClient(
    HostConfig(
      name: 'fixture',
      urls: ['ws://localhost/acp'],
      token: 'fixture',
      deviceId: 'fixture',
      deviceName: 'fixture',
    ),
  );
  final controller = _Controller(client);
  addTearDown(() {
    controller.dispose();
    client.dispose();
  });
  final req = PendingRequest('elicitation/create', {
    'message': '請回答',
    'requestedSchema': {
      'type': 'object',
      'properties': props,
      'required': props.keys.toList(),
    },
  }, CancelToken());
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showElicitationSheet(context, controller, req),
            child: const Text('回答'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('回答'));
  await tester.pumpAndSettle();
  return (controller, req);
}

void main() {
  testWidgets('shows native options and waits for explicit submission', (
    tester,
  ) async {
    final (controller, _) = await _open(tester, {'choice': _choice});
    expect(controller.action, isNull);
    await tester.tap(find.text('B'));
    await tester.pump();
    expect(controller.action, isNull);
    await tester.tap(find.text('送出'));
    await tester.pumpAndSettle();
    expect(controller.action, 'accept');
    expect(controller.answer, {'choice': 'B'});
  });

  testWidgets(
    'custom answer replaces the selected choice and a later choice replaces custom text',
    (tester) async {
      final (controller, _) = await _open(tester, {'choice': _choice});
      final custom = find.byKey(const ValueKey('elicitation-custom-choice'));
      await tester.enterText(custom, '其他 中文 🐦');
      await tester.pump();
      expect(
        tester
            .widget<RadioGroup<String>>(find.byType(RadioGroup<String>))
            .groupValue,
        isNull,
      );
      await tester.tap(find.text('B'));
      await tester.pump();
      expect(
        tester
            .widget<RadioGroup<String>>(find.byType(RadioGroup<String>))
            .groupValue,
        'B',
      );
      await tester.enterText(custom, '  自訂 中文 🐦  ');
      await tester.tap(find.text('送出'));
      await tester.pumpAndSettle();
      expect(controller.answer, {'choice': '自訂 中文 🐦'});
    },
  );

  testWidgets(
    'blank custom answer is required; multiple questions submit their respective values',
    (tester) async {
      final (controller, _) = await _open(tester, {
        'choice': _choice,
        'text': {'type': 'string', 'title': '備註'},
      });
      await tester.enterText(
        find.byKey(const ValueKey('elicitation-custom-choice')),
        ' ',
      );
      await tester.ensureVisible(find.text('送出'));
      await tester.tap(find.text('送出'));
      await tester.pump();
      expect(controller.action, isNull);
      expect(find.text('「選擇或自訂」必填'), findsOneWidget);
      await tester.ensureVisible(find.text('B'));
      await tester.tap(find.text('B'));
      await tester.enterText(
        find.byKey(const ValueKey('elicitation-text-text')),
        '備註內容',
      );
      await tester.ensureVisible(find.text('送出'));
      await tester.tap(find.text('送出'));
      await tester.pumpAndSettle();
      expect(controller.answer, {'choice': 'B', 'text': '備註內容'});
    },
  );

  for (final size in [const Size(320, 640), const Size(844, 390)]) {
    testWidgets(
      'question choices and custom entry fit at $size; cancellation withdraws form',
      (tester) async {
        final (_, req) = await _open(tester, {'choice': _choice}, size: size);
        expect(find.text('A'), findsOneWidget);
        expect(find.text('自訂回答'), findsOneWidget);
        expect(tester.takeException(), isNull);
        req.token.cancel();
        await tester.pumpAndSettle();
        expect(find.text('自訂回答'), findsNothing);
      },
    );
  }

  testWidgets('ordinary strict enums retain only their allowed choices', (
    tester,
  ) async {
    final (controller, _) = await _open(tester, {
      'choice': {
        'type': 'string',
        'oneOf': [
          {'const': 'A', 'title': '第一個', 'description': '詳細描述'},
          {'const': 'B', 'title': '第二個'},
        ],
      },
    });
    expect(find.text('自訂回答'), findsNothing);
    expect(find.text('詳細描述'), findsOneWidget);
    await tester.tap(find.text('第二個'));
    await tester.tap(find.text('送出'));
    await tester.pumpAndSettle();
    expect(controller.answer, {'choice': 'B'});
  });
}
