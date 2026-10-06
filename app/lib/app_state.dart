import 'dart:async';

import 'package:flutter/material.dart';

import 'data/app_updater.dart';
import 'data/bridge_client.dart';
import 'data/cpa_usage.dart';
import 'data/host.dart';
import 'data/history_cache.dart';
import 'data/notifications.dart';
import 'data/live_activity.dart';
import 'data/session_controller.dart';
import 'data/sessions_model.dart';
import 'data/terminal_controller.dart';

/// App-wide state: saved computers and the objects bound to the selected bridge.
class AppState extends ChangeNotifier {
  AppState(
    this.store, {
    required void Function(String sessionId) openSession,
    BridgeClient Function(HostConfig)? createClient,
    AppUpdater? updater,
  }) : notifier = LocalNotifier(openSession),
       updater = updater ?? AppUpdater(),
       _createClient = createClient ?? BridgeClient.new;

  final HostStore store;
  final LocalNotifier notifier;
  final LiveActivityController liveActivity = LiveActivityController();
  final AppUpdater updater;
  final BridgeClient Function(HostConfig) _createClient;
  List<HostConfig> _hosts = const [];
  bool _changingHost = false;
  List<HostConfig> get hosts => List.unmodifiable(_hosts);
  HostConfig? host;
  BridgeClient? client;
  SessionHub? hub;
  SessionsModel? sessions;
  TerminalHub? terminals;
  CpaController? cpa;
  StreamSubscription<void>? _cpaReconnect;
  bool loaded = false;
  ThemeMode themeMode = ThemeMode.system;
  Future<void> setThemeMode(ThemeMode mode) async {
    await store.saveAppearance(mode.name);
    themeMode = mode;
    notifyListeners();
  }

  /// A pairing link received before/while the pair screen is shown (QR scanned by the system camera).
  PairingLink? pendingPairing;

  bool get paired => host != null;

  Future<void> load() async {
    await notifier.init();
    await liveActivity.initialize();
    final library = await store.load();
    final appearance = await store.loadAppearance();
    themeMode =
        ThemeMode.values.where((mode) => mode.name == appearance).firstOrNull ??
        ThemeMode.system;
    _hosts = library.hosts;
    final h = library.activeHost;
    if (h != null) _bind(h);
    loaded = true;
    notifyListeners();
  }

  Future<void> setHost(HostConfig h) async {
    if (identical(host, h)) return;
    final next = [..._hosts];
    var index = next.indexWhere((saved) => saved.sameComputer(h));
    if (index < 0) {
      index = next.length;
      next.add(h);
    } else {
      next[index] = h;
    }
    _changingHost = true;
    try {
      await store.save(HostLibrary(hosts: next, activeIndex: index));
      _hosts = next;
      _unbind();
      _bind(h);
      notifyListeners();
    } finally {
      _changingHost = false;
    }
  }

  Future<void> forget() async {
    final current = host;
    if (current == null) return;
    final next = _hosts.where((saved) => !saved.sameComputer(current)).toList();
    _changingHost = true;
    try {
      await store.save(HostLibrary(hosts: next));
      _hosts = next;
      _unbind();
      host = null;
      await HistoryCache(current).clear();
      if (next.isNotEmpty) _bind(next.first);
      notifyListeners();
    } finally {
      _changingHost = false;
    }
  }

  void _bind(HostConfig h) {
    host = h;
    final c = _createClient(h)..start();
    client = c;
    hub = SessionHub(c);
    sessions = SessionsModel(c, cache: hub!.cache);
    liveActivity.bind(c);
    terminals = TerminalHub(c);
    final usage = CpaController(
      request: (method, params) async {
        if (!c.isOnline) throw StateError('請先連上電腦 bridge');
        return c.request(method, params);
      },
    )..startAutoRefresh();
    cpa = usage;
    unawaited(usage.initialize());
    _cpaReconnect = c.connected.listen((_) => usage.refreshIfActive());
    notifier.watch(
      c,
      (id) => c.agent(id)?.name ?? id,
      (id) => sessions?.byId(id)?.displayTitle,
    );
    // Remember which URL worked so the next start tries it first.
    c.addListener(() {
      if (_changingHost ||
          !identical(client, c) ||
          !c.isOnline ||
          identical(host, c.host)) {
        return;
      }
      host = c.host;
      _hosts = [
        for (final saved in _hosts)
          if (saved.sameComputer(c.host)) c.host else saved,
      ];
      unawaited(
        store
            .save(
              HostLibrary(hosts: _hosts, activeIndex: _hosts.indexOf(c.host)),
            )
            .catchError((Object _) {}),
      );
    });
  }

  void _unbind() {
    liveActivity.unbind();
    notifier.unwatch();
    _cpaReconnect?.cancel();
    _cpaReconnect = null;
    cpa?.dispose();
    cpa = null;
    hub?.dispose();
    sessions?.dispose();
    terminals?.dispose();
    client?.dispose();
    hub = null;
    sessions = null;
    terminals = null;
    client = null;
  }

  @override
  void dispose() {
    _unbind();
    notifier.dispose();
    liveActivity.dispose();
    updater.dispose();
    super.dispose();
  }
}

class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child})
    : super(notifier: state);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  /// Read without subscribing to rebuilds.
  static AppState read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}
