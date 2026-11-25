import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app_state.dart';
import '../common/adaptive.dart';
import '../common/app_theme.dart';
import '../sessions/host_sheet.dart';
import '../sessions/new_session_sheet.dart';
import '../sessions/sessions_page.dart';

class WorkspaceShell extends StatefulWidget {
  const WorkspaceShell({
    super.key,
    required this.location,
    required this.child,
  });
  final Uri location;
  final Widget child;

  @override
  State<WorkspaceShell> createState() => _WorkspaceShellState();
}

class _WorkspaceShellState extends State<WorkspaceShell> {
  final _scaffold = GlobalKey<ScaffoldState>();
  String? _sessionId;

  /// The wide sidebar is hidden to give the chat the whole screen.
  bool _collapsed = false;
  static const _collapsedKey = 'workspace.sidebarCollapsed';

  @override
  void initState() {
    super.initState();
    unawaited(() async {
      try {
        final saved = (await SharedPreferences.getInstance()).getBool(_collapsedKey);
        if (mounted && saved == true) setState(() => _collapsed = true);
      } catch (_) {
        // Without storage the sidebar simply starts open.
      }
    }());
  }

  void _setCollapsed(bool collapsed) {
    setState(() => _collapsed = collapsed);
    unawaited(() async {
      try {
        await (await SharedPreferences.getInstance()).setBool(_collapsedKey, collapsed);
      } catch (_) {
        // Remembering it is a convenience only.
      }
    }());
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final desktop = useWideLayout(context) && width >= desktopBreakpoint;
    final tablet = useWideLayout(context) && !desktop;
    final scheme = Theme.of(context).colorScheme;
    if (widget.location.path == '/session') {
      _sessionId = widget.location.queryParameters['id'];
    }
    if (widget.location.path == '/') _sessionId = null;
    return Scaffold(
      key: _scaffold,
      resizeToAvoidBottomInset: false,
      drawer: tablet
          ? Drawer(
              width: 320,
              child: ColoredBox(
                color: scheme.surfaceContainerLow,
                child: SessionsPage(
                  sidebar: true,
                  selectedSessionId: _sessionId,
                  onSessionSelected: () =>
                      _scaffold.currentState?.closeDrawer(),
                ),
              ),
            )
          : null,
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (desktop && _collapsed)
            ColoredBox(
              color: scheme.surfaceContainerLow,
              child: SafeArea(
                right: false,
                child: SizedBox(
                  width: 56,
                  child: Column(
                    children: [
                      const SizedBox(height: 12),
                      IconButton(
                        tooltip: '展開側邊欄',
                        icon: const Icon(Icons.menu_rounded),
                        onPressed: () => _setCollapsed(false),
                      ),
                      const SizedBox(height: 8),
                      ListenableBuilder(
                        listenable: state.client!,
                        builder: (context, _) => IconButton.filledTonal(
                          tooltip: '新對話',
                          icon: const Icon(Icons.add_rounded),
                          onPressed: state.client!.isOnline
                              ? () => showNewSessionSheet(context)
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else if (desktop)
            SizedBox(
              width: width >= 1440 ? 320 : 296,
              child: ColoredBox(
                color: scheme.surfaceContainerLow,
                child: SessionsPage(
                  sidebar: true,
                  selectedSessionId: _sessionId,
                  onCollapse: () => _setCollapsed(true),
                ),
              ),
            )
          else if (tablet)
            ColoredBox(
              color: scheme.surfaceContainerLow,
              child: SafeArea(
                child: SingleChildScrollView(
                  child: IntrinsicHeight(
                    child: NavigationRail(
                      backgroundColor: scheme.surfaceContainerLow,
                      labelType: NavigationRailLabelType.all,
                      selectedIndex: widget.location.path == '/settings'
                          ? 3
                          : widget.location.path == '/usage'
                          ? 1
                          : widget.location.path == '/terminal'
                          ? 2
                          : widget.location.path == '/desktop'
                          ? 4
                          : 0,
                      leading: Column(
                        children: [
                          IconButton(
                            tooltip: '切換電腦',
                            icon: const Icon(Icons.computer_rounded),
                            onPressed: () => showHostSheet(context),
                          ),
                          const SizedBox(height: 12),
                          ListenableBuilder(
                            listenable: state.client!,
                            builder: (context, _) => IconButton.filled(
                              // The theme's icon colour would otherwise
                              // replace the filled button's own.
                              style: IconButton.styleFrom(
                                foregroundColor: scheme.onPrimary,
                              ),
                              tooltip: '新對話',
                              icon: const Icon(Icons.add_rounded),
                              onPressed: state.client!.isOnline
                                  ? () => showNewSessionSheet(context)
                                  : null,
                            ),
                          ),
                          const SizedBox(height: 20),
                        ],
                      ),
                      onDestinationSelected: (index) {
                        if (index == 0) _scaffold.currentState?.openDrawer();
                        if (index == 1) context.go('/usage');
                        if (index == 2) context.go('/terminal');
                        if (index == 3) context.go('/settings');
                        if (index == 4) context.go('/desktop');
                      },
                      destinations: const [
                        NavigationRailDestination(
                          icon: Icon(Icons.chat_bubble_outline_rounded),
                          selectedIcon: Icon(Icons.chat_bubble_rounded),
                          label: Text('對話'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.donut_large_rounded),
                          label: Text('用量'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.terminal_rounded),
                          label: Text('終端機'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.settings_outlined),
                          selectedIcon: Icon(Icons.settings_rounded),
                          label: Text('設定'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.desktop_windows_outlined),
                          label: Text('桌面'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (desktop || tablet)
            VerticalDivider(
              width: 1,
              thickness: 1,
              color: scheme.outlineVariant.withValues(alpha: .5),
            ),
          Expanded(
            key: const ValueKey('workspace-content'),
            // A page's modal barrier hides everything painted before it from
            // screen readers; its own container keeps that off the sidebar.
            child: Semantics(container: true, child: widget.child),
          ),
        ],
      ),
    );
  }
}

class WorkspaceHome extends StatelessWidget {
  const WorkspaceHome({super.key});

  @override
  Widget build(BuildContext context) {
    if (!useWideLayout(context)) {
      return const SessionsPage();
    }
    final state = AppScope.of(context);
    final client = state.client!;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('工作區'),
        automaticallyImplyLeading: false,
      ),
      body: ContentScrollFrame(
        maxWidth: 600,
        padding: const EdgeInsets.all(32),
        builder: (context, padding) => Center(
          child: SingleChildScrollView(
            padding: padding,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer.withValues(alpha: .5),
                    borderRadius: BorderRadius.circular(CodeawRadii.xl),
                  ),
                  child: Icon(
                    Icons.forum_outlined,
                    size: 48,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  '尚未開啟對話',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 20),
                ListenableBuilder(
                  listenable: client,
                  builder: (context, _) => FilledButton.icon(
                    onPressed: client.isOnline
                        ? () => showNewSessionSheet(context)
                        : null,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('建立新對話'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
