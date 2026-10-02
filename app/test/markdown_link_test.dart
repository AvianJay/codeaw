import 'package:codeaw/acp/jsonrpc.dart';
import 'package:codeaw/app_state.dart';
import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/ui/common/markdown.dart';
import 'package:codeaw/ui/common/markdown_link.dart';
import 'package:codeaw/ui/files/file_view_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _Client extends BridgeClient {
  _Client()
    : super(
        HostConfig(
          name: 'test',
          urls: ['https://bridge.example/acp'],
          token: 'fixture',
          deviceId: 'test',
          deviceName: 'test',
        ),
      );

  String? readPath;
  bool image = false;
  RpcError? readError;

  @override
  Future<dynamic> request(String method, [Map<String, dynamic>? params]) async {
    expect(method, '_codeaw/fs/read');
    readPath = params!['path'] as String;
    if (readError case final error?) throw error;
    return {
      'binary': image,
      'size': 1,
      if (image) 'mimeType': 'image/png' else 'text': '# File preview',
    };
  }
}

Future<GoRouter> _show(
  WidgetTester tester,
  _Client client,
  String source,
) async {
  final state = AppState(HostStore(), openSession: (_) {})
    ..host = client.host
    ..client = client
    ..loaded = true;
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => Scaffold(
          body: SelectionArea(
            child: Markdown(
              '[查看畫面]($source)',
              client: client,
              basePath: r'D:\proj\codeaw',
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/file',
        builder: (_, route) => FileViewPage(
          path: route.uri.queryParameters['path']!,
          line: int.tryParse(route.uri.queryParameters['line'] ?? ''),
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  addTearDown(state.dispose);
  await tester.pumpWidget(
    AppScope(
      state: state,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

void main() {
  test(
    'resolves generated file links and source locations on the bridge OS',
    () {
      expect(
        markdownFileLink('/D:/proj/codeaw/app/test/screenshots/sessions.png'),
        (path: r'D:\proj\codeaw\app\test\screenshots\sessions.png', line: null),
      );
      expect(markdownFileLink('file:///D:/proj/My%20Project/main.dart:12:5'), (
        path: r'D:\proj\My Project\main.dart',
        line: 12,
      ));
      expect(markdownFileLink(r'D:\proj\codeaw\main.dart#L42'), (
        path: r'D:\proj\codeaw\main.dart',
        line: 42,
      ));
      expect(
        markdownFileLink('lib/main.dart#L12-L18', basePath: r'D:\proj\codeaw'),
        (path: r'D:\proj\codeaw\lib\main.dart', line: 12),
      );
      expect(
        markdownFileLink('../images/phone%20dark.png', basePath: '/home/docs'),
        (path: '/home/images/phone dark.png', line: null),
      );
      expect(markdownFileLink('</home/project/My%20Report.md:3>'), (
        path: '/home/project/My Report.md',
        line: 3,
      ));
      expect(markdownFileLink(r'\\server\share\main.dart:7'), (
        path: r'\\server\share\main.dart',
        line: 7,
      ));
      for (final source in [
        '',
        '#heading',
        'relative.md',
        'javascript:alert(1)',
        'https://example.com/file.png',
        'ftp://example.com/file.png',
        'file://[',
        'file:///project/file.md?query',
      ]) {
        expect(markdownFileLink(source), isNull, reason: source);
      }
    },
  );

  testWidgets('the screenshot link opens an authenticated image preview', (
    tester,
  ) async {
    final client = _Client()..image = true;
    final router = await _show(
      tester,
      client,
      '/D:/proj/codeaw/app/test/screenshots/sessions.png',
    );
    await tester.tap(find.text('查看畫面', findRichText: true));
    await tester.pumpAndSettle();
    const expected = r'D:\proj\codeaw\app\test\screenshots\sessions.png';
    expect(client.readPath, expected);
    expect(
      tester.widget<FileViewPage>(find.byType(FileViewPage)).path,
      expected,
    );
    final provider =
        tester.widget<Image>(find.byType(Image)).image as NetworkImage;
    final uri = Uri.parse(provider.url);
    expect(uri.host, 'bridge.example');
    expect(uri.path, '/api/fs/raw');
    expect(uri.queryParameters['path'], expected);
    expect(provider.headers, client.authHeaders);
    expect(tester.takeException(), isNull);
    router.pop();
    await tester.pumpAndSettle();
    expect(find.text('查看畫面', findRichText: true), findsOneWidget);
  });

  testWidgets('relative source links open the file at the requested line', (
    tester,
  ) async {
    final client = _Client();
    await _show(tester, client, 'docs/guide.md:12');
    await tester.tap(find.text('查看畫面', findRichText: true));
    await tester.pumpAndSettle();
    final page = tester.widget<FileViewPage>(find.byType(FileViewPage));
    expect(page.path, r'D:\proj\codeaw\docs\guide.md');
    expect(page.line, 12);
    expect(client.readPath, page.path);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is RichText &&
            widget.text.toPlainText().contains('File preview'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a rejected bridge read shows its error in the file preview', (
    tester,
  ) async {
    final client = _Client()
      ..readError = RpcError(-32602, 'Path is outside the allowed workspaces');
    await _show(tester, client, '/outside/file.md');
    await tester.tap(find.text('查看畫面', findRichText: true));
    await tester.pumpAndSettle();
    expect(find.text('Path is outside the allowed workspaces'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unsupported links report a failure instead of doing nothing', (
    tester,
  ) async {
    final client = _Client();
    await _show(tester, client, 'javascript:alert(1)');
    await tester.tap(find.text('查看畫面', findRichText: true));
    await tester.pumpAndSettle();
    expect(find.text('無法開啟這個連結'), findsOneWidget);
    expect(client.readPath, isNull);
  });
}
