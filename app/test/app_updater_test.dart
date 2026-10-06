import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codeaw/app_state.dart';
import 'package:codeaw/data/app_updater.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/main.dart';
import 'package:codeaw/ui/pair/pair_page.dart';
import 'package:codeaw/ui/settings/update_page.dart';
import 'package:codeaw/util/apk_installer_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _repository = 'AvianJay/codeaw';
final _apkUrl = Uri.parse(
  'https://github.com/$_repository/releases/download/nightly/codeaw-universal.apk',
);
final _ipaUrl = Uri.parse(
  'https://github.com/$_repository/releases/download/nightly/codeaw-ios-unsigned.ipa',
);

Map<String, dynamic> _manifest({
  UpdateChannel channel = UpdateChannel.nightly,
  String version = '0.1.0',
  int build = 42,
}) => {
  'schemaVersion': 1,
  'channel': channel.name,
  'version': version,
  'buildNumber': build,
  'releaseUrl':
      'https://github.com/$_repository/releases/tag/${channel == UpdateChannel.nightly ? 'nightly' : 'v$version'}',
  'assets': {
    for (final platform in ['android', 'ios'])
      platform: {
        'url': platform == 'android' ? _apkUrl.toString() : _ipaUrl.toString(),
        'size': 3,
        'sha256': sha256.convert([1, 2, 3]).toString(),
      },
  },
};

Future<PackageInfo> _package({
  String version = '0.1.0',
  String build = '41',
}) async => PackageInfo(
  appName: 'codeaw',
  packageName: 'tw.avianjay.codeaw',
  version: version,
  buildNumber: build,
);

AppUpdater _updater({
  http.Client? client,
  TargetPlatform platform = TargetPlatform.android,
  UpdateChannel buildChannel = UpdateChannel.nightly,
  Future<PackageInfo> Function()? loadPackage,
  ApkInstall? installApk,
  UpdateUrlLauncher? openUrl,
  bool isWeb = false,
}) => AppUpdater(
  client:
      client ??
      MockClient(
        (request) async => http.Response(
          jsonEncode(
            _manifest(
              channel: request.url.path.contains('latest')
                  ? UpdateChannel.release
                  : UpdateChannel.nightly,
            ),
          ),
          200,
        ),
      ),
  buildChannel: buildChannel,
  loadPackage: loadPackage ?? _package,
  platform: platform,
  isWeb: isWeb,
  installApk: installApk,
  openUrl: openUrl,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'nightly compares build numbers and stable compares semantic versions',
    () {
      final nightly = AppRelease.fromJson(_manifest());
      expect(nightly.isNewerThan('0.1.0', '41'), isTrue);
      expect(nightly.isNewerThan('0.1.0', '42'), isFalse);
      expect(nightly.isNewerThan('0.1.0', '43'), isFalse);
      expect(nightly.isNewerThan('0.2.0', '1'), isFalse);
      final stable = AppRelease.fromJson(
        _manifest(channel: UpdateChannel.release, version: '0.10.0', build: 1),
      );
      expect(stable.isNewerThan('0.9.0', '999'), isTrue);
    },
  );

  test('rejects malformed manifests and non-HTTPS download links', () {
    for (final manifest in [
      {..._manifest(), 'schemaVersion': 2},
      {..._manifest(), 'channel': 'unknown'},
      {..._manifest(), 'buildNumber': 0},
      {..._manifest(), 'version': 'not-a-version'},
      {
        ..._manifest(),
        'assets': {
          'android': {
            'url': 'http://example.com/update.apk',
            'size': 1,
            'sha256': 'bad',
          },
        },
      },
    ]) {
      expect(() => AppRelease.fromJson(manifest), throwsFormatException);
    }
  });

  test(
    'migrated build numbers update legacy ABI installations without resetting version codes',
    () {
      final next = AppRelease.fromJson(_manifest(build: 5017));
      for (final legacyBuild in ['14', '1014', '2014', '4014']) {
        expect(next.isNewerThan('0.1.0', legacyBuild), isTrue);
      }
      expect(next.isNewerThan('0.1.0', '5017'), isFalse);
      expect(next.isNewerThan('0.1.0', '5018'), isFalse);
      final later = AppRelease.fromJson(_manifest(build: 5018));
      expect(later.isNewerThan('0.1.0', '5017'), isTrue);
    },
  );

  test(
    'defaults to the build channel, persists changes and separates build preferences',
    () async {
      final updater = _updater();
      addTearDown(updater.dispose);
      await updater.initialize();
      expect(updater.channel, UpdateChannel.nightly);
      expect(
        updater.manifestUrl.path,
        '/$_repository/releases/download/nightly/app-update.json',
      );
      await updater.setChannel(UpdateChannel.release);
      expect(updater.channel, UpdateChannel.release);
      expect(updater.switchingChannel, isTrue);
      expect(
        updater.manifestUrl.path,
        '/$_repository/releases/latest/download/app-update.json',
      );
      final reopened = _updater();
      addTearDown(reopened.dispose);
      await reopened.initialize();
      expect(reopened.channel, UpdateChannel.release);
      await reopened.setChannel(UpdateChannel.nightly);
      final releaseBuild = _updater(buildChannel: UpdateChannel.release);
      addTearDown(releaseBuild.dispose);
      await releaseBuild.initialize();
      expect(releaseBuild.channel, UpdateChannel.release);
    },
  );

  test(
    'checks without installing and can retry a not-yet-published channel',
    () async {
      var published = false;
      var installs = 0;
      final updater = _updater(
        client: MockClient(
          (_) async => http.Response(
            published ? jsonEncode(_manifest()) : '',
            published ? 200 : 404,
          ),
        ),
        installApk: (_, _) async {
          installs++;
        },
      );
      addTearDown(updater.dispose);
      await updater.initialize();
      expect(updater.error, contains('尚未發佈'));
      expect(updater.updateAvailable, isFalse);
      published = true;
      await updater.check();
      expect(updater.error, isNull);
      expect(updater.updateAvailable, isTrue);
      expect(installs, 0);
      await updater.install();
      expect(installs, 1);
      expect(updater.message, contains('APK 安裝器'));
    },
  );

  test(
    'channel mismatches and malformed responses cannot become installable',
    () async {
      for (final body in [
        jsonEncode(_manifest(channel: UpdateChannel.release)),
        '{}',
        'not json',
      ]) {
        final updater = _updater(
          client: MockClient((_) async => http.Response(body, 200)),
        );
        await updater.initialize();
        expect(updater.error, contains('格式錯誤'));
        expect(updater.release, isNull);
        updater.dispose();
      }
    },
  );

  test(
    'a failed recheck clears a previous update instead of installing stale metadata',
    () async {
      var fail = false;
      final updater = _updater(
        client: MockClient(
          (_) async => http.Response(
            fail ? '' : jsonEncode(_manifest()),
            fail ? 503 : 200,
          ),
        ),
      );
      addTearDown(updater.dispose);
      await updater.initialize();
      expect(updater.updateAvailable, isTrue);
      fail = true;
      await updater.check();
      expect(updater.updateAvailable, isFalse);
      expect(updater.release, isNull);
      expect(updater.error, isNotNull);
    },
  );

  test('iOS installer URLs preserve nested download URL query parameters', () {
    final url = Uri.parse(
      'https://example.com/codeaw.ipa?name=a%20b&token=x%26y',
    );
    for (final method in [
      IosInstaller.altStore,
      IosInstaller.sideStore,
      IosInstaller.liveContainer,
    ]) {
      final uri = method.installUri(url);
      expect(uri.host, 'install');
      expect(uri.queryParameters['url'], url.toString());
    }
    final lc = IosInstaller.lcSign.installUri(url);
    expect(lc.scheme, 'loadcontroller');
    expect(lc.host, 'import');
    expect(lc.queryParameters['url'], url.toString());
    expect(IosInstaller.browser.installUri(url), url);
  });

  test(
    'unavailable or throwing iOS installer falls back to the browser and persists method',
    () async {
      for (final throws in [false, true]) {
        final opened = <Uri>[];
        final updater = _updater(
          platform: TargetPlatform.iOS,
          openUrl: (url) async {
            opened.add(url);
            if (url.scheme != 'https') {
              if (throws) throw StateError('not installed');
              return false;
            }
            return true;
          },
        );
        await updater.initialize();
        await updater.setIosInstaller(IosInstaller.sideStore);
        await updater.install();
        expect(opened.map((url) => url.scheme), ['sidestore', 'https']);
        expect(opened.last, _ipaUrl);
        expect(updater.error, isNull);
        expect(updater.message, contains('已改用瀏覽器'));
        updater.dispose();
      }
      final reopened = _updater(platform: TargetPlatform.iOS);
      addTearDown(reopened.dispose);
      await reopened.initialize();
      expect(reopened.iosInstaller, IosInstaller.sideStore);
    },
  );

  test('browser failures are retryable and show no success message', () async {
    final updater = _updater(
      platform: TargetPlatform.iOS,
      openUrl: (_) async => false,
    );
    addTearDown(updater.dispose);
    await updater.initialize();
    await updater.install();
    expect(updater.error, contains('無法開啟'));
    expect(updater.message, isNull);
    expect(updater.installing, isFalse);
  });

  test(
    'prevents duplicate installs and changing channels during a download',
    () async {
      final done = Completer<void>();
      var calls = 0;
      final updater = _updater(
        installApk: (_, progress) async {
          calls++;
          progress(0.5);
          await done.future;
        },
      );
      addTearDown(updater.dispose);
      await updater.initialize();
      final installing = updater.install();
      expect(updater.progress, 0.5);
      await updater.install();
      await updater.setChannel(UpdateChannel.release);
      expect(calls, 1);
      expect(updater.channel, UpdateChannel.nightly);
      done.complete();
      await installing;
      expect(updater.progress, isNull);
    },
  );

  test('web does not fetch mobile manifests', () async {
    final updater = _updater(
      isWeb: true,
      client: MockClient((_) async => throw StateError('unexpected request')),
    );
    addTearDown(updater.dispose);
    await updater.initialize();
    await updater.check();
    expect(updater.supported, isFalse);
    expect(updater.error, isNull);
    expect(updater.release, isNull);
  });

  group('APK download verification', () {
    late Directory directory;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('codeaw-updater-test-');
    });
    tearDown(() async {
      expect(
        directory.absolute.parent.path,
        Directory.systemTemp.absolute.path,
      );
      expect(
        directory.uri.pathSegments.where((value) => value.isNotEmpty).last,
        startsWith('codeaw-updater-test-'),
      );
      await directory.delete(recursive: true);
    });

    test('writes a verified APK and reports progress', () async {
      final file = File('${directory.path}/update.apk');
      final progress = <double>[];
      final client = MockClient(
        (_) async => http.Response.bytes([1, 2, 3], 200),
      );
      addTearDown(client.close);
      await downloadVerifiedApk(
        client,
        UpdateAsset.fromJson((_manifest()['assets'] as Map)['android']),
        file,
        progress.add,
      );
      expect(await file.readAsBytes(), [1, 2, 3]);
      expect(progress.first, 0);
      expect(progress.last, 1);
      expect(await File('${file.path}.part').exists(), isFalse);
    });

    for (final payload in [
      [9, 9, 9],
      [1, 2],
      [1, 2, 3, 4],
    ]) {
      test(
        'rejects corrupt or truncated APK $payload and removes partial files',
        () async {
          final file = File('${directory.path}/update.apk');
          final client = MockClient(
            (_) async => http.Response.bytes(payload, 200),
          );
          addTearDown(client.close);
          await expectLater(
            downloadVerifiedApk(
              client,
              UpdateAsset.fromJson((_manifest()['assets'] as Map)['android']),
              file,
              (_) {},
            ),
            throwsA(isA<UpdateException>()),
          );
          expect(await file.exists(), isFalse);
          expect(await File('${file.path}.part').exists(), isFalse);
        },
      );
    }

    test('a broken stream cannot leave an installable file', () async {
      final file = File('${directory.path}/update.apk');
      final client = _BrokenDownload();
      addTearDown(client.close);
      await expectLater(
        downloadVerifiedApk(
          client,
          UpdateAsset.fromJson((_manifest()['assets'] as Map)['android']),
          file,
          (_) {},
        ),
        throwsStateError,
      );
      expect(await file.exists(), isFalse);
      expect(await File('${file.path}.part').exists(), isFalse);
    });
  });

  testWidgets(
    'update screen is accessible before pairing and fits a narrow phone',
    (tester) async {
      final updater = _updater();
      final state = AppState(HostStore(), openSession: (_) {}, updater: updater)
        ..loaded = true;
      addTearDown(state.dispose);
      final router = createAppRouter(state, initialLocation: '/pair');
      addTearDown(router.dispose);
      tester.view.physicalSize = const Size(320, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        AppScope(
          state: state,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      expect(find.byType(PairPage), findsOneWidget);
      await tester.tap(find.byTooltip('App 更新'));
      await tester.pumpAndSettle();
      expect(find.byType(UpdatePage), findsOneWidget);
      expect(find.text('目前版本 0.1.0+41'), findsOneWidget);
      expect(find.text('下載並安裝 APK'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('iOS exposes the installer choices and browser fallback', (
    tester,
  ) async {
    final updater = _updater(platform: TargetPlatform.iOS);
    final state = AppState(HostStore(), openSession: (_) {}, updater: updater);
    addTearDown(state.dispose);
    await tester.pumpWidget(
      AppScope(
        state: state,
        child: const MaterialApp(home: UpdatePage()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<IosInstaller>));
    await tester.pumpAndSettle();
    for (final method in IosInstaller.values) {
      expect(find.text(method.label), findsWidgets);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

class _BrokenDownload extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(
        Stream<List<int>>.error(StateError('connection interrupted')),
        200,
      );
}
