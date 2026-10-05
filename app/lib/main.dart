import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'app_state.dart';
import 'data/host.dart';
import 'ui/chat/chat_page.dart';
import 'ui/common/app_theme.dart';
import 'ui/files/file_view_page.dart';
import 'ui/files/files_page.dart';
import 'ui/files/git_page.dart';
import 'ui/pair/pair_page.dart';
import 'ui/settings/settings_page.dart';
import 'ui/settings/update_page.dart';
import 'ui/terminal/terminal_page.dart';
import 'ui/usage/cpa_usage_page.dart';
import 'ui/workspace/workspace_shell.dart';
import 'util/browser_location.dart';

String sessionRoute(String id) => '/session?id=${Uri.encodeQueryComponent(id)}';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final launchPairing = kIsWeb ? PairingLink.fromBrowserUri(Uri.base) : null;
  if (launchPairing != null) clearBrowserPairing();
  late final GoRouter router;
  final state = AppState(
    HostStore(),
    openSession: (id) => router.go(sessionRoute(id)),
  )..pendingPairing = launchPairing;
  router = createAppRouter(state, autoPair: launchPairing != null);
  unawaited(state.load());
  runApp(CodeawApp(state: state, router: router));
}

GoRouter createAppRouter(
  AppState state, {
  bool autoPair = false,
  String? initialLocation,
}) => GoRouter(
  initialLocation: autoPair ? '/pair' : initialLocation,
  overridePlatformDefaultLocation: autoPair || initialLocation != null,
  refreshListenable: state,
  redirect: (context, s) {
    if (!state.loaded) return null;
    final atPair = s.matchedLocation == '/pair';
    if (!state.paired && !atPair && s.matchedLocation != '/updates') {
      return '/pair';
    }
    return null;
  },
  routes: [
    GoRoute(path: '/updates', builder: (_, _) => const UpdatePage()),
    GoRoute(
      path: '/pair',
      builder: (_, _) => PairPage(autoPair: autoPair),
    ),
    ShellRoute(
      builder: (_, s, child) => WorkspaceShell(
        key: ObjectKey(state.client),
        location: s.uri,
        child: child,
      ),
      routes: [
        GoRoute(path: '/', builder: (_, _) => const WorkspaceHome()),
        GoRoute(
          path: '/session',
          builder: (_, s) => ChatPage(
            key: ValueKey(s.uri.queryParameters['id']),
            sessionId: s.uri.queryParameters['id'] ?? '',
            cwd: s.uri.queryParameters['cwd'],
          ),
        ),
        GoRoute(
          path: '/files',
          builder: (_, s) => FilesPage(
            key: ValueKey(s.uri.queryParameters['path']),
            path: s.uri.queryParameters['path'] ?? '',
          ),
        ),
        GoRoute(
          path: '/file',
          builder: (_, s) => FileViewPage(
            key: ValueKey(s.uri.toString()),
            path: s.uri.queryParameters['path'] ?? '',
            line: int.tryParse(s.uri.queryParameters['line'] ?? ''),
          ),
        ),
        GoRoute(
          path: '/git',
          builder: (_, s) => GitPage(
            key: ValueKey(s.uri.queryParameters['cwd']),
            cwd: s.uri.queryParameters['cwd'] ?? '',
          ),
        ),
        GoRoute(path: '/settings', builder: (_, _) => const SettingsPage()),
        GoRoute(path: '/usage', builder: (_, _) => const CpaUsagePage()),
        GoRoute(
          path: '/terminal',
          builder: (_, s) => TerminalPage(
            key: ValueKey(s.uri.queryParameters['cwd']),
            cwd: s.uri.queryParameters['cwd'] ?? '',
          ),
        ),
      ],
    ),
  ],
);

class CodeawApp extends StatefulWidget {
  const CodeawApp({super.key, required this.state, required this.router});
  final AppState state;
  final GoRouter router;

  @override
  State<CodeawApp> createState() => _CodeawAppState();
}

class _CodeawAppState extends State<CodeawApp> {
  late final AppLifecycleListener _lifecycle;
  StreamSubscription<Uri>? _links;

  @override
  void initState() {
    super.initState();
    unawaited(widget.state.updater.initialize());
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    if (!kIsWeb) {
      final appLinks = AppLinks();
      _links = appLinks.uriLinkStream.listen(_onLink);
    }
  }

  void _onLifecycle(AppLifecycleState s) {
    final foreground = s == AppLifecycleState.resumed;
    widget.state.notifier.foreground = foreground;
    widget.state.liveActivity.foreground = foreground;
    widget.state.client?.setForeground(foreground);
    if (foreground) unawaited(widget.state.liveActivity.refresh());
  }

  void _onLink(Uri uri) {
    if (uri.scheme != 'codeaw') return;
    if (uri.host == 'session') {
      final id = Uri.decodeComponent(uri.path.replaceFirst('/', ''));
      if (id.isNotEmpty && widget.state.paired) {
        widget.router.go(sessionRoute(id));
      }
    } else if (uri.host == 'pair') {
      final link = PairingLink.parse(uri.toString());
      if (link != null) {
        widget.state.pendingPairing = link;
        widget.router.go('/pair');
      }
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _links?.cancel();
    super.dispose();
  }

  ThemeData _theme(Brightness b) => codeawTheme(b);

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: widget.state,
      child: ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) {
          if (!widget.state.loaded) {
            return MaterialApp(
              theme: _theme(Brightness.light),
              darkTheme: _theme(Brightness.dark),
              home: const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              ),
            );
          }
          return MaterialApp.router(
            title: 'codeaw',
            debugShowCheckedModeBanner: false,
            theme: _theme(Brightness.light),
            darkTheme: _theme(Brightness.dark),
            themeMode: widget.state.themeMode,
            routerConfig: widget.router,
          );
        },
      ),
    );
  }
}
