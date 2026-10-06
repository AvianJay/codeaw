import 'dart:async';
import 'dart:convert';
import 'package:codeaw/app_state.dart';
import 'package:codeaw/data/app_updater.dart';
import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/live_activity.dart';
import 'package:codeaw/main.dart';
import 'package:codeaw/ui/sessions/sessions_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StartupClient extends BridgeClient {
  _StartupClient(super.host) {
    status = ConnStatus.online;
  }
  @override
  void start() {}
  @override
  Future<dynamic> request(String method, [Map<String, dynamic>? params]) async {
    if (method == 'session/list') return {'sessions': []};
    if (method == '_codeaw/activity/list') return {'activities': []};
    return {};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final recover in [true, false]) {
    testWidgets(
      'saved chats render while retained native activity ${recover ? 'recovers' : 'never responds'}',
      (tester) async {
        const notifications = MethodChannel(
          'dexterous.com/flutter/local_notifications',
        );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              notifications,
              (call) async => call.method == 'getNotificationAppLaunchDetails'
                  ? {'notificationLaunchedApp': false}
                  : true,
            );
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(notifications, null),
        );
        SharedPreferences.setMockInitialValues({});
        final host = HostConfig(
          name: 'codex',
          urls: ['ws://pc/acp'],
          token: 'test',
          deviceId: 'phone',
          deviceName: 'test',
        );
        FlutterSecureStorage.setMockInitialValues({
          'codeaw.host': jsonEncode(host.toJson()),
        });
        final native = Completer<dynamic>();
        var calls = 0;
        final activity = LiveActivityController(
          platformSupported: true,
          nativeCall: (method, params) {
            if (method == 'status') {
              calls++;
              return native.future;
            }
            return Future.value({});
          },
        );
        final state = AppState(
          HostStore(),
          openSession: (_) {},
          createClient: _StartupClient.new,
          liveActivity: activity,
          updater: AppUpdater(platform: TargetPlatform.windows),
        );
        final router = createAppRouter(state, initialLocation: '/');
        addTearDown(() {
          router.dispose();
          state.dispose();
        });
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        unawaited(state.load());
        await tester.pumpWidget(CodeawApp(state: state, router: router));
        await tester.pumpAndSettle();
        expect(state.loaded, isTrue);
        expect(find.byType(SessionsPage), findsOneWidget);
        expect(calls, 1);
        expect(native.isCompleted, isFalse);
        if (recover) {
          native.complete({
            'supported': true,
            'authorized': true,
            'activities': [
              {
                'activityId': 'retained',
                'hostKey': host.deviceId,
                'sessionId': 'codex:1',
                'turnId': 'old-turn',
              },
            ],
          });
        } else {
          await tester.pump(const Duration(seconds: 6));
        }
        await state.initializePlatformFeatures();
        await tester.pumpAndSettle();
        expect(find.byType(SessionsPage), findsOneWidget);
        if (!recover) expect(activity.error, isNotNull);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
      variant: const TargetPlatformVariant({TargetPlatform.iOS}),
    );
  }
}
