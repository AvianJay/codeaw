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

CpaQuota allowance(
  double? weekly,
  double? fiveHour, {
  String status = 'ok',
  List<Map<String, dynamic>> extra = const [],
}) => CpaQuota.fromJson({
  'status': status,
  'windows': [
    {'id': 'weekly', 'remainingPercent': weekly},
    {'id': 'five-hour', 'remainingPercent': fiveHour},
    ...extra,
  ],
});

CpaQuota agyAllowance(List<double> weekly, List<double> fiveHour) =>
    CpaQuota.fromJson({
      'status': 'ok',
      'windows': [
        for (var i = 0; i < weekly.length; i++)
          {
            'id': 'group-$i-weekly',
            'remainingPercent': weekly[i],
            'periodSeconds': 604800,
          },
        for (var i = 0; i < fiveHour.length; i++)
          {
            'id': 'group-$i-five-hour',
            'remainingPercent': fiveHour[i],
            'periodSeconds': 18000,
          },
      ],
    });

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('averages weekly and five-hour by account, separately by provider', () {
    final accounts = [
      for (final id in ['c1', 'c2', 'c3'])
        CpaAccount.fromJson(account(id, 'codex')),
      CpaAccount.fromJson(account('claude', 'claude')),
      CpaAccount.fromJson(account('agy1', 'antigravity')),
      CpaAccount.fromJson(account('agy2', 'antigravity')),
    ];
    final values = cpaProviderAverages(accounts, {
      'c1': allowance(
        97,
        100,
        extra: [
          {
            'id': 'review-weekly',
            'remainingPercent': 0,
            'periodSeconds': 604800,
          },
        ],
      ),
      'c2': allowance(23, 50),
      'c3': allowance(20, 0),
      'claude': allowance(
        81,
        72,
        extra: [
          {
            'id': 'seven_day_sonnet',
            'remainingPercent': 0,
            'periodSeconds': 604800,
          },
        ],
      ),
      'agy1': agyAllowance([90, 30], [100, 60]),
      'agy2': agyAllowance([20], [40]),
    });
    expect(values.map((v) => v.provider), ['codex', 'claude', 'antigravity']);
    expect(values[0].weekly.remainingPercent, closeTo(140 / 3, 1e-10));
    expect(values[0].fiveHour.remainingPercent, 50);
    expect(values[0].weekly.accountCount, 3);
    expect(values[0].totalAccounts, 3);
    expect(values[1].weekly.remainingPercent, 81);
    expect(values[1].fiveHour.remainingPercent, 72);
    expect(values[2].label, 'AGY');
    // Equal weight per account despite different numbers of AGY model groups.
    expect(values[2].weekly.remainingPercent, 40);
    expect(values[2].fiveHour.remainingPercent, 60);
    expect(values[2].weekly.accountCount, 2);
  });

  test('excludes unknown, failed, disabled and invalid values per window', () {
    final accounts = [
      for (final id in [
        'zero',
        'weekly-only',
        'invalid',
        'failed',
        'missing',
        'disabled',
        'unavailable',
      ])
        CpaAccount.fromJson({
          ...account(id, 'codex'),
          'disabled': id == 'disabled',
          'unavailable': id == 'unavailable',
        }),
    ];
    final value = cpaProviderAverages(accounts, {
      'zero': allowance(0, 0),
      'weekly-only': allowance(100, null),
      'invalid': allowance(double.nan, 101),
      'failed': allowance(90, 90, status: 'error'),
      'disabled': allowance(90, 90),
      'unavailable': allowance(90, 90),
    }).single;
    expect(value.totalAccounts, 7);
    expect(value.weekly.remainingPercent, 50);
    expect(value.weekly.accountCount, 2);
    expect(value.fiveHour.remainingPercent, 0);
    expect(value.fiveHour.accountCount, 1);
  });

  test(
    'no main quota stays unknown, without borrowing model-specific quotas',
    () {
      final values = cpaProviderAverages(
        [
          CpaAccount.fromJson(account('codex', 'codex')),
          CpaAccount.fromJson(account('claude', 'claude')),
          CpaAccount.fromJson(account('gemini', 'gemini')),
        ],
        {
          'codex': CpaQuota.fromJson({
            'status': 'ok',
            'windows': [
              {
                'id': 'review-weekly',
                'remainingPercent': 90,
                'periodSeconds': 604800,
              },
            ],
          }),
          'claude': CpaQuota.fromJson({
            'status': 'ok',
            'windows': [
              {
                'id': 'seven_day_sonnet',
                'remainingPercent': 80,
                'periodSeconds': 604800,
              },
            ],
          }),
          'gemini': CpaQuota.fromJson({'status': 'unsupported'}),
        },
      );
      for (final value in values) {
        expect(value.weekly.remainingPercent, isNull);
        expect(value.weekly.accountCount, 0);
        expect(value.fiveHour.remainingPercent, isNull);
      }
      expect(cpaProviderAverages([], {}), isEmpty);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'shows one-decimal provider averages and quota colors in $brightness',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final c = CpaController(request: (_, _) async => {})
          ..initialized = true
          ..settings = settings
          ..accounts = [
            for (final id in ['c1', 'c2', 'c3'])
              CpaAccount.fromJson(account(id, 'codex')),
            CpaAccount.fromJson(account('claude', 'claude')),
            CpaAccount.fromJson(account('agy', 'antigravity')),
            CpaAccount.fromJson(account('grok', 'grok')),
          ];
        c.quotas.addAll({
          'c1': allowance(97, 100),
          'c2': allowance(23, 50),
          'c3': allowance(20, 0),
          'claude': allowance(81, 72),
          'agy': agyAllowance([60], [30]),
          'grok': allowance(64, null),
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: codeawTheme(brightness),
            home: CpaUsagePage(controller: c),
          ),
        );
        await tester.pumpAndSettle();
        final green = brightness == Brightness.dark
            ? const Color(0xFF4ADE80)
            : const Color(0xFF15803D);
        final yellow = brightness == Brightness.dark
            ? const Color(0xFFFBBF24)
            : const Color(0xFFB77900);
        for (final entry in {
          'codex': [46.666666666666664, 50.0, yellow, green],
          'claude': [81.0, 72.0, green, green],
          'antigravity': [60.0, 30.0, green, yellow],
        }.entries) {
          final row = find.byKey(ValueKey('cpa-average-${entry.key}'));
          expect(
            find.descendant(
              of: row,
              matching: find.text(
                '週: ${(entry.value[0] as double).toStringAsFixed(1)}%',
              ),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: row,
              matching: find.text(
                '5小時: ${(entry.value[1] as double).toStringAsFixed(1)}%',
              ),
            ),
            findsOneWidget,
          );
          final bars = tester
              .widgetList<LinearProgressIndicator>(
                find.descendant(
                  of: row,
                  matching: find.byType(LinearProgressIndicator),
                ),
              )
              .toList();
          expect(
            bars[0].value,
            closeTo((entry.value[0] as double) / 100, 1e-10),
          );
          expect(bars[1].value, (entry.value[1] as double) / 100);
          expect(bars[0].color, entry.value[2]);
          expect(bars[1].color, entry.value[3]);
        }
        // A provider with only a weekly window shows no five-hour bar.
        final grok = find.byKey(const ValueKey('cpa-average-grok'));
        expect(
          find.descendant(of: grok, matching: find.text('週: 64.0%')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: grok, matching: find.textContaining('5小時')),
          findsNothing,
        );
        expect(
          find.descendant(
            of: grok,
            matching: find.byType(LinearProgressIndicator),
          ),
          findsOneWidget,
        );
        await tester.enterText(find.byType(TextField), 'claude');
        await tester.pumpAndSettle();
        expect(find.text('週: 46.7%'), findsOneWidget);
        expect(find.text('3 個帳號'), findsOneWidget);
        await tester.tap(find.byTooltip('清除搜尋'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'Codex'));
        await tester.tap(find.widgetWithText(ChoiceChip, 'Codex'));
        await tester.pumpAndSettle();
        final chip = tester.widget<ChoiceChip>(
          find.widgetWithText(ChoiceChip, 'Codex'),
        );
        expect(chip.selected, isTrue);
        final listScroll = find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('cpa-average-codex')),
          -150,
          scrollable: listScroll,
        );
        expect(find.text('週: 81.0%'), findsOneWidget);
        expect(find.text('週: 46.7%'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        c.dispose();
      },
    );
  }

  testWidgets(
    'auto refreshes at 30 seconds, pauses in background and skips overlapping requests',
    (tester) async {
      var calls = 0;
      Completer<Map<String, dynamic>>? pending;
      final c = CpaController(
        request: (method, params) async {
          if (method == '_codeaw/cpa/accounts') {
            calls++;
            return pending?.future ??
                {
                  'accounts': [account('codex', 'codex')],
                };
          }
          return quota('codex');
        },
      )..initialized = true;
      await c.configure(settings);
      await tester.pumpWidget(MaterialApp(home: CpaUsagePage(controller: c)));
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      final initialCalls = calls;
      await tester.pump(const Duration(seconds: 29));
      expect(calls, initialCalls);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(calls, initialCalls + 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 80));
      expect(calls, initialCalls + 1);
      pending = Completer<Map<String, dynamic>>();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(calls, initialCalls + 2);
      await tester.pump(const Duration(seconds: 10));
      expect(calls, initialCalls + 2);
      pending.complete({'accounts': []});
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
      await tester.pump(const Duration(seconds: 30));
      expect(calls, initialCalls + 2);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'quota colors include boundaries, unknown and narrow enlarged text in $brightness',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final c = CpaController(request: (_, _) async => {})
          ..initialized = true
          ..settings = settings
          ..accounts = [CpaAccount.fromJson(account('codex', 'codex'))];
        final dark = brightness == Brightness.dark;
        for (final (value, expectedColor) in <(double?, Color?)>[
          (0, dark ? const Color(0xFFF87171) : const Color(0xFFDC2626)),
          (19.9, dark ? const Color(0xFFF87171) : const Color(0xFFDC2626)),
          (20, dark ? const Color(0xFFFBBF24) : const Color(0xFFB77900)),
          (49.9, dark ? const Color(0xFFFBBF24) : const Color(0xFFB77900)),
          (50, dark ? const Color(0xFF4ADE80) : const Color(0xFF15803D)),
          (100, dark ? const Color(0xFF4ADE80) : const Color(0xFF15803D)),
          (null, null),
        ]) {
          c.quotas['codex'] = allowance(value, value);
          await tester.pumpWidget(
            MaterialApp(
              theme: codeawTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(1.6)),
                child: child!,
              ),
              home: CpaUsagePage(controller: c),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final row = find.byKey(const ValueKey('cpa-average-codex'));
          if (value == null) {
            // No reported window at all: the provider row is not shown.
            expect(row, findsNothing);
            continue;
          }
          final bars = tester.widgetList<LinearProgressIndicator>(
            find.descendant(
              of: row,
              matching: find.byType(LinearProgressIndicator),
            ),
          );
          final label = '${value.toStringAsFixed(1)}%';
          expect(
            find.descendant(of: row, matching: find.text('週: $label')),
            findsOneWidget,
          );
          expect(
            find.descendant(of: row, matching: find.text('5小時: $label')),
            findsOneWidget,
          );
          expect(bars.every((bar) => bar.color == expectedColor), isTrue);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        c.dispose();
      },
    );
  }

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
    'publishes quotas together after slow and failed accounts settle',
    () async {
      var delayed = false;
      final pending = <String, Completer<Map<String, dynamic>>>{};
      final c = CpaController(
        request: (method, params) async {
          if (method == '_codeaw/cpa/accounts') {
            return {
              'accounts': [
                for (final id in ['c1', 'c2', 'c3']) account(id, 'codex'),
                account('claude', 'claude'),
              ],
            };
          }
          final id = params['accountId'] as String;
          if (delayed) {
            return (pending[id] = Completer<Map<String, dynamic>>()).future;
          }
          return {
            'status': 'ok',
            'windows': [
              {
                'id': 'weekly',
                'remainingPercent': {
                  'c1': 97,
                  'c2': 23,
                  'c3': 20,
                  'claude': 80,
                }[id],
              },
              {'id': 'five-hour', 'remainingPercent': 50},
            ],
          };
        },
      );
      addTearDown(c.dispose);
      await c.configure(settings);
      final before = cpaProviderAverages(c.accounts, c.quotas);
      final oldTimestamp = c.updatedAt;
      delayed = true;
      final refresh = c.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(c.loading, isTrue);
      expect(c.updatedAt, oldTimestamp);
      final observed = <double?>[];
      c.addListener(
        () => observed.add(
          cpaProviderAverages(
            c.accounts,
            c.quotas,
          ).first.weekly.remainingPercent,
        ),
      );
      pending['c2']!.complete({
        'status': 'ok',
        'windows': [
          {'id': 'weekly', 'remainingPercent': 20},
          {'id': 'five-hour', 'remainingPercent': 40},
        ],
      });
      await Future<void>.delayed(Duration.zero);
      pending['claude']!.complete({
        'status': 'ok',
        'windows': [
          {'id': 'weekly', 'remainingPercent': 60},
          {'id': 'five-hour', 'remainingPercent': 70},
        ],
      });
      pending['c1']!.complete({
        'status': 'ok',
        'windows': [
          {'id': 'weekly', 'remainingPercent': 10},
          {'id': 'five-hour', 'remainingPercent': 20},
        ],
      });
      await Future<void>.delayed(Duration.zero);
      expect(
        observed.every((v) => v == before.first.weekly.remainingPercent),
        isTrue,
      );
      expect(c.quotas['claude']!.windows.first.remainingPercent, 80);
      expect(c.loading, isTrue);
      pending['c3']!.completeError(StateError('quota unavailable'));
      await refresh;
      final after = cpaProviderAverages(c.accounts, c.quotas);
      expect(after.first.weekly.remainingPercent, 15);
      expect(after.first.fiveHour.remainingPercent, 30);
      expect(after.first.weekly.accountCount, 2);
      expect(after[1].weekly.remainingPercent, 60);
      expect(after[1].fiveHour.remainingPercent, 70);
      expect(c.quotas['c3']!.status, 'error');
      expect(observed.last, 15);
      expect(c.loading, isFalse);
      expect(c.loadingQuotas, isEmpty);
    },
  );

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
      final listScroll = find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('codex@example.com'),
        100,
        scrollable: listScroll,
      );
      expect(find.text('codex@example.com'), findsOneWidget);
      expect(find.text('剩餘 75%'), findsWidgets);
      expect(find.byType(Card), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.byType(TextField),
        -100,
        scrollable: listScroll,
      );
      await tester.enterText(find.byType(TextField), 'claude');
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('claude@example.com'),
        100,
        scrollable: listScroll,
      );
      expect(find.text('claude@example.com'), findsOneWidget);
      expect(find.text('codex@example.com'), findsNothing);
      await tester.scrollUntilVisible(
        find.byType(TextField),
        -100,
        scrollable: listScroll,
      );
      await tester.tap(find.byTooltip('清除搜尋'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'Codex'));
      await tester.tap(find.widgetWithText(ChoiceChip, 'Codex'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('codex@example.com'),
        100,
        scrollable: listScroll,
      );
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
