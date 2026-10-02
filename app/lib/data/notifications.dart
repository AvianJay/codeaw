import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'bridge_client.dart';

/// Local notifications while the app is in the background but still connected
/// (when it is not connected at all, the bridge pushes through ntfy instead).
class LocalNotifier {
  LocalNotifier(this.onOpenSession);

  final void Function(String sessionId) onOpenSession;
  final _plugin = FlutterLocalNotificationsPlugin();
  final _lastState = <String, String>{};
  bool _ready = false;
  bool foreground = true;
  StreamSubscription<Map<String, dynamic>>? _sub;

  static const _channel = AndroidNotificationDetails(
    'codeaw_attention',
    '需要注意',
    channelDescription: 'Agent 需要批准或已完成工作',
    importance: Importance.high,
    priority: Priority.high,
  );

  Future<void> init() async {
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
        onDidReceiveNotificationResponse: (r) {
          final id = r.payload;
          if (id != null && id.isNotEmpty) onOpenSession(id);
        },
      );
      final launch = await _plugin.getNotificationAppLaunchDetails();
      final payload = launch?.notificationResponse?.payload;
      if ((launch?.didNotificationLaunchApp ?? false) && payload != null) onOpenSession(payload);
      _ready = true;
    } catch (_) {
      _ready = false;
    }
  }

  Future<void> requestPermission() async {
    await _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
  }

  void watch(BridgeClient client, String Function(String agentId) agentName, String? Function(String sessionId) title) {
    _sub?.cancel();
    _sub = client.activity.listen((a) {
      final id = a['sessionId'] as String?;
      final state = a['state'] as String?;
      if (id == null || state == null) return;
      final prev = _lastState[id];
      _lastState[id] = state;
      if (foreground || !_ready || prev == state) return;
      final agent = agentName('${a['agentId'] ?? id.split(':').first}');
      final name = (a['title'] as String?) ?? title(id) ?? '';
      if (state == 'requires_action') {
        unawaited(_show(id, '$agent 需要你的批准', name));
      } else if (state == 'idle' && (prev == 'running' || prev == 'requires_action')) {
        unawaited(_show(id, '$agent 已完成', name));
      }
    });
  }

  Future<void> _show(String sessionId, String title, String body) =>
      _plugin.show(id: sessionId.hashCode & 0x7fffffff, title: title, body: body, notificationDetails: const NotificationDetails(android: _channel), payload: sessionId);

  void dispose() => _sub?.cancel();
}
