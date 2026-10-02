import 'package:codeaw/acp/jsonrpc.dart';
import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/session_controller.dart';
import 'package:codeaw/ui/chat/composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Client extends BridgeClient {
  _Client({bool modelCategory = true})
    : super(
        HostConfig(
          name: 'fixture',
          urls: ['ws://localhost/acp'],
          token: 'fixture',
          deviceId: 'fixture',
          deviceName: 'fixture',
        ),
      ) {
    config = [
      {
        'id': modelCategory ? 'active_model' : 'model',
        'name': 'Model',
        if (modelCategory) 'category': 'model',
        'type': 'select',
        'currentValue': 'standard',
        'options': [
          {
            'name': 'Available models',
            'options': [
              {'value': 'standard', 'name': 'Standard'},
              {'value': 'fast', 'name': 'Fast'},
            ],
          },
        ],
      },
      {
        'id': 'mode',
        'name': 'Mode',
        'category': 'mode',
        'type': 'select',
        'currentValue': 'ask',
        'options': [
          {'value': 'ask', 'name': 'Ask'},
          {'value': 'code', 'name': 'Code'},
        ],
      },
    ];
  }

  late List<Map<String, dynamic>> config;
  final requests = <Map<String, dynamic>>[];
  bool reject = false;

  @override
  Future<dynamic> request(String method, [Map<String, dynamic>? params]) async {
    expect(method, 'session/set_config_option');
    requests.add(params!);
    if (reject) throw RpcError(-32602, 'Unknown model');
    config = [
      for (final option in config)
        {
          ...option,
          if (option['id'] == params['configId'])
            'currentValue': params['value'],
        },
    ];
    return {'configOptions': config};
  }
}

Future<({SessionController controller, _Client client})> _show(
  WidgetTester tester, {
  Size size = const Size(1000, 800),
  bool modelCategory = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final client = _Client(modelCategory: modelCategory);
  final controller = SessionController(client, 'fixture:one');
  controller.timeline.configOptions = client.config;
  addTearDown(() {
    controller.dispose();
    client.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ListenableBuilder(
          listenable: controller,
          builder: (_, _) => ConfigBar(controller: controller),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Standard'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('自訂模型名稱'));
  await tester.pumpAndSettle();
  return (controller: controller, client: client);
}

void main() {
  for (final phone in [true, false]) {
    testWidgets(
      'custom model reaches the agent on ${phone ? 'phone' : 'desktop'}',
      (tester) async {
        final h = await _show(
          tester,
          size: phone ? const Size(390, 844) : const Size(1000, 800),
          modelCategory: !phone,
        );
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'standard',
        );
        await tester.enterText(
          find.byType(TextField),
          '  provider/My.Model-v2  ',
        );
        if (phone) {
          tester.view.viewInsets = const FakeViewPadding(bottom: 320);
          await tester.pumpAndSettle();
          expect(
            tester.getBottomRight(find.widgetWithText(FilledButton, '套用')).dy,
            lessThanOrEqualTo(844 - 320),
          );
          await tester.tap(find.widgetWithText(FilledButton, '套用'));
          tester.view.resetViewInsets();
        } else {
          await tester.testTextInput.receiveAction(TextInputAction.done);
        }
        await tester.pumpAndSettle();

        expect(h.client.requests, [
          {
            'sessionId': 'fixture:one',
            'configId': phone ? 'model' : 'active_model',
            'value': 'provider/My.Model-v2',
          },
        ]);
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.text('provider/My.Model-v2'), findsOneWidget);

        // A model outside the advertised list can still be edited or replaced.
        await tester.tap(find.text('provider/My.Model-v2'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('自訂模型名稱'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'provider/My.Model-v2',
        );
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Fast'));
        await tester.pumpAndSettle();
        expect(h.client.requests.last['value'], 'fast');
        expect(find.text('Fast'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('blank, unchanged, and cancelled input do not change config', (
    tester,
  ) async {
    final h = await _show(tester);
    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '套用'))
          .onPressed,
      isNull,
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(h.client.requests, isEmpty);

    await tester.enterText(find.byType(TextField), 'discard-this-model');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(h.client.requests, isEmpty);
    await tester.tap(find.text('自訂模型名稱'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), ' standard ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(h.client.requests, isEmpty);

    await tester.tap(find.text('Ask'));
    await tester.pumpAndSettle();
    expect(find.text('自訂模型名稱'), findsNothing);
    await tester.tap(find.text('Code'));
    await tester.pumpAndSettle();
    expect(h.client.requests.single['configId'], 'mode');
    expect(h.client.requests.single['value'], 'code');
  });

  testWidgets(
    'agent rejection preserves the selected model and reports its error',
    (tester) async {
      final h = await _show(tester);
      h.client.reject = true;
      final errors = <String>[];
      final subscription = h.controller.toasts.listen(errors.add);
      addTearDown(subscription.cancel);
      await tester.enterText(find.byType(TextField), 'unknown-model');
      await tester.tap(find.text('套用'));
      await tester.pumpAndSettle();

      expect(h.client.requests.single['value'], 'unknown-model');
      expect(errors, ['Unknown model']);
      expect(find.text('Standard'), findsOneWidget);
      expect(h.controller.configOptions.first.currentValue, 'standard');
      expect(tester.takeException(), isNull);
    },
  );
}
