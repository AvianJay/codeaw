import 'package:codeaw/data/android_live_activity.dart';
import 'package:codeaw/data/live_activity.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final platform in [
    TargetPlatform.iOS,
    TargetPlatform.android,
    TargetPlatform.windows,
  ]) {
    test(
      'only the selected platform owns the live activity channel on $platform',
      () async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        SharedPreferences.setMockInitialValues({});
        final methods = <String>[];
        const channel = MethodChannel('codeaw/live_activity');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              methods.add(call.method);
              return {
                'supported': true,
                'authorized': true,
                'available': true,
                'allowed': true,
              };
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null),
        );
        final ios = LiveActivityController();
        final android = LiveActivityTracker();
        await ios.initialize();
        await android.load();
        if (platform == TargetPlatform.iOS) {
          expect(ios.supported, isTrue);
          expect(android.channel.platformSupported, isFalse);
          expect(methods, contains('status'));
          expect(methods, isNot(contains('support')));
          expect(methods, isNot(contains('show')));
        } else if (platform == TargetPlatform.android) {
          expect(ios.supported, isFalse);
          expect(android.channel.platformSupported, isTrue);
          expect(methods, containsAll(['show', 'support']));
          expect(methods, isNot(contains('status')));
        } else {
          expect(methods, isEmpty);
        }
        ios.dispose();
        android.dispose();
      },
    );
  }
}
