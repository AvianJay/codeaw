import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../data/bridge_client.dart';
import '../../data/app_updater.dart';

/// Shows an update once per version, after the root navigator is ready.
class AppUpdatePrompt extends StatefulWidget {
  const AppUpdatePrompt({
    super.key,
    required this.updater,
    required this.navigatorKey,
    required this.openUpdates,
    required this.child,
    this.bridge,
    this.routes,
    this.isUpdatePage,
  });

  final AppUpdater updater;
  final GlobalKey<NavigatorState> navigatorKey;
  final VoidCallback openUpdates;
  final Widget child;
  final BridgeClient? bridge;
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
    widget.bridge?.addListener(_onBridgeChanged);
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
    if (oldWidget.bridge != widget.bridge) {
      oldWidget.bridge?.removeListener(_onBridgeChanged);
      widget.bridge?.addListener(_onBridgeChanged);
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

  void _onBridgeChanged() {
    if (mounted) setState(() {});
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
    widget.bridge?.removeListener(_onBridgeChanged);
    widget.routes?.removeListener(_schedule);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bridge = !kIsWeb ? widget.bridge?.bridgeUpdate : null;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (bridge?.active == true) _BridgeUpdateStatus(update: bridge!),
      ],
    );
  }
}

/// A non-blocking mobile status surface for a bridge update started at launch.
class _BridgeUpdateStatus extends StatelessWidget {
  const _BridgeUpdateStatus({required this.update});

  final BridgeUpdateInfo update;

  @override
  Widget build(BuildContext context) {
    final downloading = update.state == 'downloading';
    final installing = update.state == 'installing';
    final progress = update.progress;
    final title = downloading && progress != null
        ? 'Bridge 更新中 ${(progress * 100).round()}%'
        : installing
        ? 'Bridge 更新中…'
        : '正在檢查 Bridge 更新…';
    final subtitle = installing
        ? '更新完成後會自動重新啟動'
        : downloading
        ? '正在下載並驗證更新'
        : '正在準備更新';
    return Positioned(
      top: 0,
      left: 12,
      right: 12,
      child: IgnorePointer(
        child: SafeArea(
          bottom: false,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Card(
                margin: const EdgeInsets.only(top: 8),
                elevation: 4,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          SizedBox(
                            width: 20,
                            height: 20,
                            child: installing && progress != null
                                ? CircularProgressIndicator(value: progress)
                                : const CircularProgressIndicator(),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              title,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      LinearProgressIndicator(value: progress),
                      const SizedBox(height: 5),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
