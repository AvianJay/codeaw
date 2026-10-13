import 'dart:async';
import 'dart:io';

import 'package:codeaw/acp/jsonrpc.dart';
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
        HostConfig(
          name: 'dev-pc',
          urls: ['ws://localhost/acp'],
          token: 'test',
          deviceId: 'test',
          deviceName: 'test',
        ),
      ) {
    status = ConnStatus.online;
  }

  final writes = <String>[];
  final writeIds = <String>[];
  final opens = <Map<String, dynamic>>[];
  final sessions = <String, Map<String, dynamic>>{};
  final detached = <String>[];
  final reconnected = StreamController<void>.broadcast();
  final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  bool race = false;
  bool failClose = false;
  bool loseOpenResponse = false;
  int nextId = 0;
  int maxTerminals = 8;
  String? activeId;
  Completer<void>? pendingOpen;

  @override
  Stream<void> get connected => reconnected.stream;

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
      case '_codeaw/terminal/list':
        return {
          'terminals': sessions.values.toList(),
          'activeTerminalId': activeId,
          'maxTerminals': maxTerminals,
        };
      case '_codeaw/terminal/open':
        opens.add(Map.of(params!));
        var id = params['terminalId'] as String?;
        id ??=
            sessions.values
                    .where(
                      (s) =>
                          s['creationId'] == params['creationId'] &&
                          params['creationId'] != null,
                    )
                    .firstOrNull?['terminalId']
                as String?;
        if (id == null) {
          id = 'term_test_${++nextId}';
          sessions[id] = {
            'terminalId': id,
            'creationId': params['creationId'],
            'cwd': params['cwd'],
            'shell': 'powershell.exe',
            'exited': false,
            'events': [
              {
                'terminalId': id,
                'seq': 1,
                'type': 'data',
                'data':
                    '\x1b[32mPS D:\\proj\\codeaw>\x1b[0m git status\r\nOn branch master\r\n\r\nChanges not staged for commit:\r\n  \x1b[31mmodified:   app/lib/main.dart\x1b[0m\r\n\r\n\x1b[32mPS D:\\proj\\codeaw>\x1b[0m ',
              },
              if (race)
                {
                  'terminalId': id,
                  'seq': 2,
                  'type': 'data',
                  'data': 'raced-output\r\n',
                },
            ],
          };
        }
        if (!sessions.containsKey(id)) {
          throw RpcError(-32602, 'Terminal not found');
        }
        activeId = id;
        if (race) {
          events.add({
            'terminalId': id,
            'seq': 2,
            'type': 'data',
            'data': 'raced-output\r\n',
          });
        }
        await pendingOpen?.future;
        if (loseOpenResponse) {
          loseOpenResponse = false;
          throw RpcError(RpcError.connectionClosed, 'Connection closed');
        }
        final history = sessions[id]!['events'] as List;
        final after = params['afterSeq'] as int? ?? 0;
        return {
          ...sessions[id]!,
          'lastSeq': history.length,
          'full': after == 0,
          'events': history.where((e) => (e['seq'] as int) > after).toList(),
        };
      case '_codeaw/terminal/write':
        writes.add(params!['data'] as String);
        writeIds.add(params['terminalId'] as String);
        return {};
      case '_codeaw/terminal/detach':
        detached.add(params!['terminalId'] as String);
        return {};
      case '_codeaw/terminal/close':
        if (failClose) throw StateError('close failed');
        sessions.remove(params!['terminalId']);
        if (activeId == params['terminalId']) {
          activeId = sessions.keys.lastOrNull;
        }
        return {};
      default:
        return {};
    }
  }

  void goOffline() {
    status = ConnStatus.offline;
    notifyListeners();
  }

  void goOnline() {
    status = ConnStatus.online;
    notifyListeners();
    reconnected.add(null);
  }

  void emit(String id, String data) {
    final history = sessions[id]!['events'] as List;
    final event = {
      'terminalId': id,
      'seq': history.length + 1,
      'type': 'data',
      'data': data,
    };
    history.add(event);
    events.add(event);
  }

  @override
  void dispose() {
    events.close();
    reconnected.close();
    super.dispose();
  }
}

AppState _state(_TerminalClient client) =>
    AppState(HostStore(), openSession: (_) {})
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
  testWidgets(
    'selects a workspace, sends shortcuts and disables input offline at phone width',
    (tester) async {
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
      expect(
        tester.widget<TerminalView>(find.byType(TerminalView)).keyboardType,
        TextInputType.visiblePassword,
      );
      await tester.tap(find.text('Ctrl+C'));
      await tester.pump();
      expect(client.writes, contains('\x03'));
      client.goOffline();
      await tester.pumpAndSettle();
      expect(
        tester.widget<TerminalView>(find.byType(TerminalView)).readOnly,
        isTrue,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Ctrl+C'))
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      state.terminals!.dispose();
      client.dispose();
    },
  );

  test(
    'deduplicates terminal events that arrive before the open response',
    () async {
      final client = _TerminalClient()..race = true;
      final controller = ShellController(client, _cwd);
      await controller.attach();
      expect(
        'raced-output'.allMatches(controller.terminal.buffer.getText()),
        hasLength(1),
      );
      expect(controller.lastSeq, 2);
      controller.dispose();
      client.dispose();
    },
  );

  testWidgets(
    'creates, switches and closes independent tabs in one directory',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final client = _TerminalClient();
      final state = _state(client);
      await tester.pumpWidget(_wrap(state, const TerminalPage(cwd: _cwd)));
      await tester.pumpAndSettle();
      final first = state.terminals!.active!;
      client.emit(first.terminalId!, 'first-only\r\n');
      await tester.tap(find.byTooltip('新增終端機'));
      await tester.pumpAndSettle();
      final second = state.terminals!.active!;
      expect(second.terminalId, isNot(first.terminalId));
      expect(client.opens.where((p) => p['createNew'] == true), hasLength(2));
      client.emit(second.terminalId!, 'second-only\r\n');
      client.emit(first.terminalId!, 'background-output\r\n');
      await tester.tap(find.text('codeaw · 1'));
      await tester.pumpAndSettle();
      expect(state.terminals!.active, same(first));
      expect(first.terminal.buffer.getText(), contains('first-only'));
      expect(first.terminal.buffer.getText(), contains('background-output'));
      expect(first.terminal.buffer.getText(), isNot(contains('second-only')));
      await tester.tap(find.text('Ctrl+C'));
      await tester.pump();
      expect(client.writeIds.last, first.terminalId);
      await tester.tap(find.byTooltip('關閉終端機 1'));
      await tester.pumpAndSettle();
      expect(state.terminals!.controllers, [second]);
      expect(state.terminals!.active, same(second));
      expect(client.sessions.keys, [second.terminalId]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      state.terminals!.dispose();
      client.dispose();
    },
  );

  testWidgets(
    'restores tabs, selection and detached output after recreating the app state',
    (tester) async {
      final client = _TerminalClient();
      var state = _state(client);
      await tester.pumpWidget(_wrap(state, const TerminalPage(cwd: _cwd)));
      await tester.pumpAndSettle();
      final firstId = state.terminals!.active!.terminalId!;
      await tester.tap(find.byTooltip('新增終端機'));
      await tester.pumpAndSettle();
      final secondId = state.terminals!.active!.terminalId!;
      await tester.pumpWidget(const SizedBox());
      state.terminals!.dispose();
      client.emit(firstId, 'retained-first\r\n');
      client.emit(secondId, 'retained-second\r\n');

      state = _state(client);
      await tester.pumpWidget(_wrap(state, const TerminalPage()));
      await tester.pumpAndSettle();
      expect(state.terminals!.controllers.map((c) => c.terminalId), [
        firstId,
        secondId,
      ]);
      expect(state.terminals!.active!.terminalId, secondId);
      expect(
        state.terminals!.active!.terminal.buffer.getText(),
        contains('retained-second'),
      );
      expect(client.nextId, 2);
      await tester.tap(find.text('codeaw · 1'));
      await tester.pumpAndSettle();
      expect(
        state.terminals!.active!.terminal.buffer.getText(),
        contains('retained-first'),
      );
      client.goOffline();
      client.emit(firstId, 'during-disconnect\r\n');
      client.goOnline();
      await tester.pumpAndSettle();
      expect(state.terminals!.active!.terminalId, firstId);
      expect(
        'during-disconnect'.allMatches(
          state.terminals!.active!.terminal.buffer.getText(),
        ),
        hasLength(1),
      );
      expect(client.nextId, 2);
      await tester.pumpWidget(const SizedBox());
      state.terminals!.dispose();
      client.dispose();
    },
  );

  testWidgets(
    'reconciles a restarted bridge, respects the tab limit and retains failed closes',
    (tester) async {
      final client = _TerminalClient()..maxTerminals = 1;
      final state = _state(client);
      await tester.pumpWidget(_wrap(state, const TerminalPage(cwd: _cwd)));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (w) => w is IconButton && w.tooltip == '新增終端機',
              ),
            )
            .onPressed,
        isNull,
      );
      client.failClose = true;
      await tester.tap(find.byTooltip('關閉終端機 1'));
      await tester.pumpAndSettle();
      expect(state.terminals!.controllers, hasLength(1));
      expect(find.textContaining('close failed'), findsOneWidget);
      client.goOffline();
      client.sessions.clear();
      client.goOnline();
      await tester.pumpAndSettle();
      expect(state.terminals!.controllers, isEmpty);
      expect(find.byType(TerminalView), findsNothing);
      expect(find.text('codeaw'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      state.terminals!.dispose();
      client.dispose();
    },
  );

  test(
    'detaches a terminal whose creation finishes after navigating away',
    () async {
      final client = _TerminalClient()..pendingOpen = Completer<void>();
      final controller = ShellController(client, _cwd);
      final opening = controller.attach();
      controller.detach();
      client.pendingOpen!.complete();
      await opening;
      expect(controller.attached, isFalse);
      expect(client.detached, contains(controller.terminalId));
      expect(client.sessions, hasLength(1));
      await controller.attach();
      expect(controller.attached, isTrue);
      expect(client.nextId, 1);
      controller.dispose();
      client.dispose();
    },
  );

  testWidgets(
    'recovers a lost open response without duplicating its tab or shell',
    (tester) async {
      final client = _TerminalClient()..loseOpenResponse = true;
      final state = _state(client);
      await tester.pumpWidget(_wrap(state, const TerminalPage(cwd: _cwd)));
      await tester.pumpAndSettle();
      final pending = state.terminals!.active!;
      expect(pending.terminalId, isNull);
      expect(client.sessions, hasLength(1));
      client.goOffline();
      client.goOnline();
      await tester.pumpAndSettle();
      expect(state.terminals!.controllers, [pending]);
      expect(pending.terminalId, client.sessions.keys.single);
      expect(pending.canInput, isTrue);
      expect(client.nextId, 1);
      await tester.pumpWidget(const SizedBox());
      state.terminals!.dispose();
      client.dispose();
    },
  );

  testWidgets(
    'bundled terminal font gives narrow and wide ASCII identical cell widths',
    (tester) async {
      final loader = FontLoader('JetBrainsMono')
        ..addFont(rootBundle.load('assets/fonts/JetBrainsMono-Regular.ttf'))
        ..addFont(rootBundle.load('assets/fonts/JetBrainsMono-Bold.ttf'));
      await loader.load();
      final client = _TerminalClient();
      final state = _state(client);
      await tester.pumpWidget(_wrap(state, const TerminalPage(cwd: _cwd)));
      await tester.pumpAndSettle();
      final style = tester
          .widget<TerminalView>(find.byType(TerminalView))
          .textStyle;
      double width(String text, {bool bold = false}) {
        final painter = TextPainter(
          text: TextSpan(
            text: text,
            style: style.toTextStyle(bold: bold),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        final width = painter.width;
        painter.dispose();
        return width;
      }

      expect(width('iiiiiiiiii'), closeTo(width('mmmmmmmmmm'), .01));
      expect(width('WWWWWWWWWW'), closeTo(width('mmmmmmmmmm'), .01));
      expect(
        width('iiiiiiiiii', bold: true),
        closeTo(width('mmmmmmmmmm'), .01),
      );
      expect(width('mmmmmmmmmm') / 10 / style.fontSize, closeTo(.6, .01));
      await tester.pumpWidget(const SizedBox());
      state.terminals!.dispose();
      client.dispose();
    },
  );

  testWidgets(
    'terminal phone screenshot',
    (tester) async {
      for (final font in {
        'Roboto':
            'D:/flutter/bin/cache/artifacts/material_fonts/roboto-regular.ttf',
        'MaterialIcons':
            'D:/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        'NotoSansTC': 'C:/Windows/Fonts/NotoSansTC-VF.ttf',
        'JetBrainsMono': 'assets/fonts/JetBrainsMono-Regular.ttf',
      }.entries) {
        if (File(font.value).existsSync()) {
          final loader = FontLoader(font.key)
            ..addFont(
              Future.value(
                ByteData.sublistView(File(font.value).readAsBytesSync()),
              ),
            );
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
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('screenshots/terminal.png'),
      );
      await tester.pumpWidget(const SizedBox());
      state.terminals!.dispose();
      client.dispose();
    },
    skip: Platform.environment['CODEAW_SCREENSHOTS'] != '1',
  );
}
