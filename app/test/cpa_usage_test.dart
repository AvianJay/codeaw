import 'dart:async';

import 'package:codeaw/data/cpa_usage.dart';
import 'package:codeaw/ui/common/app_theme.dart';
import 'package:codeaw/ui/usage/cpa_usage_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const settings = CpaSettings(
  endpoint: 'https://cpa.example.com',
  managementKey: 'private-test-key',
);
Map<String, dynamic> account(String id, String provider) => {
  'id': id,
  'provider': provider,
  'label': '$id@example.com',
  'plan': 'Plus',
  'status': 'active',
  'requests': 42,
};
Map<String, dynamic> quota(String id) => {
  'accountId': id,
  'status': 'ok',
  'resetsRemaining': id == 'codex' ? 1 : null,
  'windows': [
    {
      'id': 'five-hour',
      'label': '5 小時',
      'remainingPercent': 75,
      'resetAt': DateTime.now()
          .add(const Duration(hours: 2))
          .toUtc()
          .toIso8601String(),
    },
    {
      'id': 'weekly',
      'label': '每週',
      'remainingPercent': 96,
      'resetAt': DateTime.now()
          .add(const Duration(days: 5))
          .toUtc()
          .toIso8601String(),
    },
  ],
};

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'persists connection in secure storage and removes credentials',
    () async {
      final store = CpaStore();
      expect(await store.load(), isNull);
      await store.save(settings);
      expect((await store.load())!.endpoint, settings.endpoint);
      expect((await store.load())!.managementKey, settings.managementKey);
      await store.clear();
      expect(await store.load(), isNull);
    },
  );

  test(
    'refreshes separate account quotas, and failure replaces old percentages',
    () async {
      var failQuota = false;
      final c = CpaController(
        request: (method, params) async {
          expect(params['managementKey'], settings.managementKey);
          if (method == '_codeaw/cpa/accounts') {
            return {
              'accounts': [
                account('codex', 'codex'),
                account('claude', 'claude'),
              ],
            };
          }
          if (failQuota) throw StateError('private-test-key rejected');
          return quota(params['accountId'] as String);
        },
      );
      addTearDown(c.dispose);
      await c.configure(settings);
      expect(c.accounts.length, 2);
      expect(c.quotas['codex']!.resetsRemaining, 1);
      expect(c.quotas['codex']!.windows.first.remainingPercent, 75);
      failQuota = true;
      await c.refreshAccount('codex');
      expect(c.quotas['codex']!.windows, isEmpty);
      expect(c.quotas['codex']!.message, isNot(contains('private-test-key')));
      expect(c.loadingQuotas, isEmpty);
    },
  );

  test('old responses cannot overwrite a newly configured endpoint', () async {
    final old = Completer<Map<String, dynamic>>();
    final c = CpaController(
      request: (_, params) async {
        if (params['endpoint'] == settings.endpoint) return old.future;
        return {'accounts': []};
      },
    );
    addTearDown(c.dispose);
    final first = c.configure(settings);
    await Future<void>.delayed(Duration.zero);
    await c.configure(
      const CpaSettings(
        endpoint: 'https://new.example.com',
        managementKey: 'new-key',
      ),
    );
    old.complete({
      'accounts': [account('old', 'codex')],
    });
    await first;
    expect(c.settings!.endpoint, 'https://new.example.com');
    expect(c.accounts, isEmpty);
  });

  test(
    'does not fabricate a quota or automatically replenish it after its reset time',
    () {
      final q = CpaQuota.fromJson({
        'status': 'ok',
        'windows': [
          {
            'id': 'five-hour',
            'label': '5 小時',
            'resetAt': '2026-10-04T01:00:00Z',
          },
        ],
      });
      expect(q.resetsRemaining, isNull);
      expect(q.windows.first.remainingPercent, isNull);
      expect(
        cpaResetCountdown(q.windows.first.resetAt, DateTime.utc(2026, 10, 5)),
        contains('請重新整理'),
      );
      expect(cpaResetCountdown(null, DateTime.utc(2026, 10, 5)), '重置時間未知');
    },
  );

  for (final size in [
    const Size(320, 640),
    const Size(390, 844),
    const Size(844, 390),
    const Size(1200, 800),
  ]) {
    testWidgets('shows compact account lines and filters at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = CpaController(
        request: (method, params) async => method == '_codeaw/cpa/accounts'
            ? {
                'accounts': [
                  account('codex', 'codex'),
                  account('claude', 'claude'),
                  account('grok', 'grok'),
                ],
              }
            : quota(params['accountId'] as String),
      );
      c.initialized = true;
      await c.configure(settings);
      await tester.pumpWidget(
        MaterialApp(
          theme: codeawTheme(Brightness.light),
          home: CpaUsagePage(controller: c),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('用量與額度'), findsOneWidget);
      expect(find.text('codex@example.com'), findsOneWidget);
      expect(find.text('剩餘 75%'), findsWidgets);
      expect(find.byType(Card), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.enterText(find.byType(TextField), 'claude');
      await tester.pumpAndSettle();
      expect(find.text('claude@example.com'), findsOneWidget);
      expect(find.text('codex@example.com'), findsNothing);
      await tester.tap(find.byTooltip('清除搜尋'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Codex'));
      await tester.pumpAndSettle();
      expect(find.text('codex@example.com'), findsOneWidget);
      expect(find.text('claude@example.com'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    });
  }

  testWidgets(
    'validates custom endpoint and hides the management key by default',
    (tester) async {
      final c = CpaController(request: (_, _) async => {'accounts': []})
        ..initialized = true;
      await tester.pumpWidget(
        MaterialApp(
          theme: codeawTheme(Brightness.dark),
          home: CpaUsagePage(controller: c),
        ),
      );
      await tester.tap(find.text('連接 CPA'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).last).obscureText,
        isTrue,
      );
      await tester.tap(find.text('儲存並連線'));
      await tester.pumpAndSettle();
      expect(find.text('請輸入 Management Key'), findsOneWidget);
      await tester.enterText(
        find.byType(TextFormField).first,
        'https://cpa.example.com',
      );
      await tester.enterText(
        find.byType(TextFormField).last,
        'private-test-key',
      );
      await tester.tap(find.text('儲存並連線'));
      await tester.pumpAndSettle();
      expect(c.settings!.endpoint, 'https://cpa.example.com');
      expect(find.text('CPA 尚未加入帳號'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );
}
