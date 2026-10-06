import 'package:codeaw/data/cpa_usage.dart';
import 'package:codeaw/ui/chat/chat_header.dart';
import 'package:codeaw/ui/usage/cpa_usage_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

CpaController _usage() {
  final c = CpaController(request: (_, _) async => {})
    ..initialized = true
    ..settings = const CpaSettings(
      endpoint: 'http://fixture',
      managementKey: 'test',
    )
    ..accounts = [
      for (final id in ['c1', 'c2', 'c3'])
        CpaAccount.fromJson({'id': id, 'provider': 'codex'}),
      CpaAccount.fromJson({'id': 'claude', 'provider': 'claude'}),
      CpaAccount.fromJson({'id': 'agy', 'provider': 'antigravity'}),
    ];
  for (final (id, weekly, five) in [
    ('c1', 97, 100),
    ('c2', 23, 50),
    ('c3', 20, 0),
    ('claude', 12, 72),
    ('agy', 90, 10),
  ]) {
    c.quotas[id] = CpaQuota.fromJson({
      'status': 'ok',
      'windows': [
        {'id': 'weekly', 'remainingPercent': weekly},
        {'id': 'five-hour', 'remainingPercent': five},
      ],
    });
  }
  return c;
}

void main() {
  for (final size in [
    const Size(320, 640),
    const Size(390, 844),
    const Size(844, 390),
  ]) {
    testWidgets(
      'header quota fits beside title at $size and changes with agent',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final c = _usage();
        addTearDown(c.dispose);
        var opened = false;
        Widget page(String agent) => MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              toolbarHeight: size.height < 500 ? 44 : 56,
              leading: const BackButton(),
              titleSpacing: 0,
              title: ChatHeaderTitle(
                title: 'A very long conversation title that should truncate',
                subtitle: 'desktop sync',
                agentId: agent,
                agentName: agent,
                usage: c,
                onUsageTap: () => opened = true,
              ),
              actions: [
                if (size.width >= 360)
                  const IconButton(onPressed: null, icon: Icon(Icons.folder)),
                const IconButton(onPressed: null, icon: Icon(Icons.more_vert)),
              ],
            ),
          ),
        );
        for (final (agent, weekly, five, color) in [
          ('codex', '46.7%', '50.0%', const Color(0xFFB77900)),
          ('claude', '12.0%', '72.0%', const Color(0xFFDC2626)),
          ('agy', '90.0%', '10.0%', const Color(0xFF15803D)),
          ('other', '—', '—', null),
        ]) {
          await tester.pumpWidget(page(agent));
          await tester.pumpAndSettle();
          final bars = find.byKey(const ValueKey('chat-usage-bars'));
          expect(
            find.descendant(of: bars, matching: find.text('週: $weekly')),
            findsOneWidget,
          );
          expect(
            find.descendant(of: bars, matching: find.text('5hr: $five')),
            findsOneWidget,
          );
          expect(
            find.descendant(of: bars, matching: find.text(agent)),
            findsNothing,
          );
          if (color != null) {
            expect(
              tester
                  .widget<LinearProgressIndicator>(
                    find
                        .descendant(
                          of: bars,
                          matching: find.byType(LinearProgressIndicator),
                        )
                        .first,
                  )
                  .color,
              color,
            );
          }
          expect(tester.getRect(bars).right, lessThanOrEqualTo(size.width));
          expect(tester.takeException(), isNull);
        }
        await tester.tap(find.byKey(const ValueKey('chat-usage-bars')));
        expect(opened, isTrue);
        c.settings = null;
        await tester.pumpWidget(page('codex'));
        expect(find.byKey(const ValueKey('chat-usage-bars')), findsNothing);
      },
    );
  }

  testWidgets(
    'chat and usage page share one poller and leave it active after returning',
    (tester) async {
      var calls = 0;
      final c =
          CpaController(
              request: (method, _) async {
                if (method == '_codeaw/cpa/accounts') {
                  calls++;
                  return {'accounts': []};
                }
                return {};
              },
            )
            ..initialized = true
            ..settings = const CpaSettings(
              endpoint: 'http://fixture',
              managementKey: 'test',
            );
      c.startAutoRefresh();
      await tester.pumpWidget(MaterialApp(home: CpaUsagePage(controller: c)));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      final initial = calls;
      await tester.pump(const Duration(seconds: 30));
      expect(calls, initial + 1);
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ChatHeaderTitle(
            title: 'Chat',
            subtitle: '',
            agentId: 'codex',
            agentName: 'Codex',
            usage: c,
          )),
        ),
      );
      await tester.pump(const Duration(seconds: 30));
      expect(calls, initial + 2);
      c.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
