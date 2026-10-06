import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/app_updater.dart';

/// Shows an update once per version, after the root navigator is ready.
class AppUpdatePrompt extends StatefulWidget {
  const AppUpdatePrompt({
    super.key,
    required this.updater,
    required this.navigatorKey,
    required this.openUpdates,
    required this.child,
    this.routes,
    this.isUpdatePage,
  });

  final AppUpdater updater;
  final GlobalKey<NavigatorState> navigatorKey;
  final VoidCallback openUpdates;
  final Widget child;
  final Listenable? routes;
  final bool Function()? isUpdatePage;

  @override
  State<AppUpdatePrompt> createState() => _AppUpdatePromptState();
}

class _AppUpdatePromptState extends State<AppUpdatePrompt>
    with WidgetsBindingObserver {
  bool _scheduled = false;
  bool _showing = false;
  bool _foreground = true;
  final Set<String> _shown = {};

  @override
  void initState() {
    super.initState();
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    widget.updater.addListener(_schedule);
    widget.routes?.addListener(_schedule);
    unawaited(widget.updater.initialize());
    _schedule();
  }

  @override
  void didUpdateWidget(AppUpdatePrompt oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.updater != widget.updater) {
      oldWidget.updater.removeListener(_schedule);
      widget.updater.addListener(_schedule);
      _shown.clear();
      unawaited(widget.updater.initialize());
    }
    if (oldWidget.routes != widget.routes) {
      oldWidget.routes?.removeListener(_schedule);
      widget.routes?.addListener(_schedule);
    }
    _schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      unawaited(widget.updater.checkIfStale());
      _schedule();
    }
  }

  void _schedule() {
    if (!mounted || _scheduled || _showing) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) unawaited(_showIfAvailable());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _showIfAvailable() async {
    final updater = widget.updater;
    final id = updater.availableUpdateId;
    final context = widget.navigatorKey.currentContext;
    if (!_foreground ||
        _showing ||
        !updater.shouldPromptUpdate ||
        id == null ||
        _shown.contains(id) ||
        context == null ||
        widget.isUpdatePage?.call() == true) {
      return;
    }
    _showing = true;
    _shown.add(id);
    unawaited(updater.markUpdatePromptShown());
    final version =
        '${updater.channel.name} ${updater.release!.displayVersion}';
    final open = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.system_update_rounded),
        title: const Text('發現新版本'),
        content: Text(
          '$version\n'
          '開啟檢查更新後，選擇你自己的安裝方式。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('稍後'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('開啟檢查更新'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    _showing = false;
    if (open == true) widget.openUpdates();
    _schedule();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.updater.removeListener(_schedule);
    widget.routes?.removeListener(_schedule);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
