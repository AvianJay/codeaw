import 'dart:async';
import 'dart:io';

import 'package:codeaw/app_state.dart';
import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/terminal_controller.dart';
import 'package:codeaw/ui/terminal/terminal_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

const _cwd = r'D:\proj\codeaw';

class _TerminalClient extends BridgeClient {
  _TerminalClient()
    : super(
        HostConfig(name: 'dev-pc', urls: ['ws://localhost/acp'], token: 'test', deviceId: 'test', deviceName: 'test'),
      ) {
    status = ConnStatus.online;
  }

  final writes = <String>[];
  final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  bool race = false;

  @override
  Stream<Map<String, dynamic>> get terminalEvents => events.stream;

  @override
  Future<dynamic> request(String method, [Map<String, dynamic>? params]) async {
    switch (method) {
      case '_codeaw/workspaces/list':
        return {
          'roots': [
            {'path': _cwd, 'name': 'codeaw', 'source': 'config'},
          ],
        };
      case '_codeaw/terminal/open':
        if (race) events.add({'terminalId': 'term_test', 'seq': 2, 'type': 'data', 'data': 'raced-output\r\n'});
        return {
          'terminalId': 'term_test',
          'cwd': _cwd,
          'shell': 'powershell.exe',
          'lastSeq': race ? 2 : 1,
          'full': true,
          'exited': false,
          'events': [
            {
              'terminalId': 'term_test',
              'seq': 1,
              'type': 'data',
              'data':
                  '\x1b[32mPS D:\\proj\\codeaw>\x1b[0m git status\r\nOn branch master\r\n\r\nChanges not staged for commit:\r\n  \x1b[31mmodified:   app/lib/main.dart\x1b[0m\r\n\r\n\x1b[32mPS D:\\proj\\codeaw>\x1b[0m ',
            },
            if (race) {'terminalId': 'term_test', 'seq': 2, 'type': 'data', 'data': 'raced-output\r\n'},
          ],
        };
      case '_codeaw/terminal/write':
        writes.add(params!['data'] as String);
        return {};
      default:
        return {};
    }
  }

  void goOffline() {
    status = ConnStatus.offline;
    notifyListeners();
  }

  @override
  void dispose() {
    events.close();
    super.dispose();
  }
}

AppState _state(_TerminalClient client) => AppState(HostStore(), openSession: (_) {})
  ..client = client
  ..terminals = TerminalHub(client)
  ..loaded = true;

Widget _wrap(AppState state, Widget child) => AppScope(
  state: state,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorSchemeSeed: const Color(0xFF0F9D8A),
      fontFamily: 'Roboto',
      fontFamilyFallback: const ['NotoSansTC'],
    ),
    home: child,
  ),
);

void main() {
  testWidgets('selects a workspace, sends shortcuts and disables input offline at phone width', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final client = _TerminalClient();
    final state = _state(client);
    await tester.pumpWidget(_wrap(state, const TerminalPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('codeaw'));
    await tester.pumpAndSettle();
    expect(find.byType(TerminalView), findsOneWidget);
    expect(tester.widget<TerminalView>(find.byType(TerminalView)).keyboardType, TextInputType.visiblePassword);
    await tester.tap(find.text('Ctrl+C'));
    await tester.pump();
    expect(client.writes, contains('\x03'));
    client.goOffline();
    await tester.pumpAndSettle();
    expect(tester.widget<TerminalView>(find.byType(TerminalView)).readOnly, isTrue);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Ctrl+C')).onPressed, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    state.terminals!.dispose();
    client.dispose();
  });

  test('deduplicates terminal events that arrive before the open response', () async {
    final client = _TerminalClient()..race = true;
    final controller = ShellController(client, _cwd);
    await controller.attach();
    expect('raced-output'.allMatches(controller.terminal.buffer.getText()), hasLength(1));
    expect(controller.lastSeq, 2);
    controller.dispose();
    client.dispose();
  });

  testWidgets('terminal phone screenshot', (tester) async {
    for (final font in {
      'Roboto': 'D:/flutter/bin/cache/artifacts/material_fonts/roboto-regular.ttf',
      'MaterialIcons': 'D:/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      'NotoSansTC': 'C:/Windows/Fonts/NotoSansTC-VF.ttf',
      'monospace': 'C:/Windows/Fonts/consola.ttf',
    }.entries) {
      if (File(font.value).existsSync()) {
        final loader = FontLoader(font.key)
          ..addFont(Future.value(ByteData.sublistView(File(font.value).readAsBytesSync())));
        await loader.load();
      }
    }
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final client = _TerminalClient();
    final state = _state(client);
    await tester.pumpWidget(_wrap(state, const TerminalPage(cwd: _cwd)));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('screenshots/terminal.png'));
    await tester.pumpWidget(const SizedBox());
    state.terminals!.dispose();
    client.dispose();
  }, skip: Platform.environment['CODEAW_SCREENSHOTS'] != '1');
}
