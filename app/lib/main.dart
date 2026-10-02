import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'app_state.dart';
import 'data/host.dart';
import 'ui/chat/chat_page.dart';
import 'ui/files/file_view_page.dart';
import 'ui/files/files_page.dart';
import 'ui/files/git_page.dart';
import 'ui/pair/pair_page.dart';
import 'ui/sessions/sessions_page.dart';
import 'ui/settings/settings_page.dart';
import 'ui/terminal/terminal_page.dart';
import 'util/browser_location.dart';

String sessionRoute(String id) => '/session?id=${Uri.encodeQueryComponent(id)}';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final launchPairing = kIsWeb ? PairingLink.fromBrowserUri(Uri.base) : null;
  if (launchPairing != null) clearBrowserPairing();
  late final GoRouter router;
  final state = AppState(HostStore(), openSession: (id) => router.go(sessionRoute(id)))
    ..pendingPairing = launchPairing;
  router = GoRouter(
    initialLocation: launchPairing == null ? null : '/pair',
    overridePlatformDefaultLocation: launchPairing != null,
    refreshListenable: state,
    redirect: (context, s) {
      if (!state.loaded) return null;
      final atPair = s.matchedLocation == '/pair';
      if (!state.paired && !atPair) return '/pair';
      return null;
    },
    routes: [
      GoRoute(path: '/', builder: (_, _) => const SessionsPage()),
      GoRoute(path: '/pair', builder: (_, _) => PairPage(autoPair: launchPairing != null)),
      GoRoute(path: '/session', builder: (_, s) => ChatPage(sessionId: s.uri.queryParameters['id'] ?? '', cwd: s.uri.queryParameters['cwd'])),
      GoRoute(path: '/files', builder: (_, s) => FilesPage(path: s.uri.queryParameters['path'] ?? '')),
      GoRoute(path: '/file', builder: (_, s) => FileViewPage(path: s.uri.queryParameters['path'] ?? '', line: int.tryParse(s.uri.queryParameters['line'] ?? ''))),
      GoRoute(path: '/git', builder: (_, s) => GitPage(cwd: s.uri.queryParameters['cwd'] ?? '')),
      GoRoute(path: '/settings', builder: (_, _) => const SettingsPage()),
      GoRoute(path: '/terminal', builder: (_, s) => TerminalPage(cwd: s.uri.queryParameters['cwd'] ?? '')),
    ],
  );
  unawaited(state.load());
  runApp(CodeawApp(state: state, router: router));
}

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
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    if (!kIsWeb) {
      final appLinks = AppLinks();
      _links = appLinks.uriLinkStream.listen(_onLink);
    }
  }

  void _onLifecycle(AppLifecycleState s) {
    final foreground = s == AppLifecycleState.resumed;
    widget.state.notifier.foreground = foreground;
    widget.state.client?.setForeground(foreground);
  }

  void _onLink(Uri uri) {
    if (uri.scheme != 'codeaw') return;
    if (uri.host == 'session') {
      final id = Uri.decodeComponent(uri.path.replaceFirst('/', ''));
      if (id.isNotEmpty && widget.state.paired) widget.router.go(sessionRoute(id));
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

  ThemeData _theme(Brightness b) {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF0F9D8A), brightness: b);
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      visualDensity: VisualDensity.standard,
      appBarTheme: AppBarTheme(backgroundColor: scheme.surface, scrolledUnderElevation: 1),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: widget.state,
      child: ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) {
          if (!widget.state.loaded) {
            return MaterialApp(theme: _theme(Brightness.light), darkTheme: _theme(Brightness.dark), home: const Scaffold(body: Center(child: CircularProgressIndicator())));
          }
          return MaterialApp.router(
            title: 'codeaw',
            debugShowCheckedModeBanner: false,
            theme: _theme(Brightness.light),
            darkTheme: _theme(Brightness.dark),
            routerConfig: widget.router,
          );
        },
      ),
    );
  }
}
