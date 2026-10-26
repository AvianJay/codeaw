import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/app_updater.dart';

/// Starts automatic updates through [AppUpdater] and keeps a manual prompt for
/// callers that opt out of that flow.
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
    // The phone app starts the install itself. Do not put a confirmation
    // dialog in front of that flow; the status banner below is enough to make
    // the operation visible without blocking the current screen.
    if (updater.autoUpdate) return;
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
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.updater,
    builder: (context, _) => Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (widget.updater.autoUpdate && widget.updater.supported)
          _AutomaticUpdateStatus(updater: widget.updater),
      ],
    ),
  );
}

/// A small, non-blocking mobile status surface for an update started at app
/// launch or when the app returns to the foreground.
class _AutomaticUpdateStatus extends StatelessWidget {
  const _AutomaticUpdateStatus({required this.updater});

  final AppUpdater updater;

  @override
  Widget build(BuildContext context) {
    if (!updater.checking && !updater.installing) {
      return const SizedBox.shrink();
    }
    final progress = updater.progress;
    final installing = updater.installing;
    final title = installing
        ? progress == null
              ? '更新中…'
              : '更新中 ${(progress * 100).round()}%'
        : '檢查更新中…';
    final subtitle = installing ? '更新完成後會由系統接續安裝' : '正在準備手機更新';
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
