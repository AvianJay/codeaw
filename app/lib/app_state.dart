import 'dart:async';

import 'package:flutter/widgets.dart';

import 'data/bridge_client.dart';
import 'data/host.dart';
import 'data/notifications.dart';
import 'data/session_controller.dart';
import 'data/sessions_model.dart';
import 'data/terminal_controller.dart';

/// App-wide state: the paired bridge and the objects bound to its connection.
class AppState extends ChangeNotifier {
  AppState(this.store, {required void Function(String sessionId) openSession}) : notifier = LocalNotifier(openSession);

  final HostStore store;
  final LocalNotifier notifier;
  HostConfig? host;
  BridgeClient? client;
  SessionHub? hub;
  SessionsModel? sessions;
  TerminalHub? terminals;
  bool loaded = false;

  /// A pairing link received before/while the pair screen is shown (QR scanned by the system camera).
  PairingLink? pendingPairing;

  bool get paired => host != null;

  Future<void> load() async {
    await notifier.init();
    final h = await store.load();
    if (h != null) _bind(h);
    loaded = true;
    notifyListeners();
  }

  Future<void> setHost(HostConfig h) async {
    await store.save(h);
    _unbind();
    _bind(h);
    notifyListeners();
  }

  Future<void> forget() async {
    await store.clear();
    _unbind();
    host = null;
    notifyListeners();
  }

  void _bind(HostConfig h) {
    host = h;
    final c = BridgeClient(h)..start();
    client = c;
    hub = SessionHub(c);
    sessions = SessionsModel(c);
    terminals = TerminalHub(c);
    notifier.watch(c, (id) => c.agent(id)?.name ?? id, (id) => sessions?.byId(id)?.displayTitle);
    // Remember which URL worked so the next start tries it first.
    c.addListener(() {
      if (c.isOnline && h.urls.first != c.host.urls.first) unawaited(store.save(c.host));
    });
  }

  void _unbind() {
    hub?.dispose();
    sessions?.dispose();
    terminals?.dispose();
    client?.dispose();
    hub = null;
    sessions = null;
    terminals = null;
    client = null;
  }
}

class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  /// Read without subscribing to rebuilds.
  static AppState read(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}
