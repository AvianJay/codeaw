import 'dart:convert';

import 'package:codeaw/acp/jsonrpc.dart';
import 'package:codeaw/app_state.dart';
import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/ui/common/code_view.dart';
import 'package:codeaw/ui/common/markdown.dart';
import 'package:codeaw/ui/common/markdown_blocks.dart';
import 'package:codeaw/ui/common/markdown_details.dart';
import 'package:codeaw/ui/common/markdown_visualization.dart';
import 'package:codeaw/ui/files/file_view_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _screenshotReference =
    '\uE200visualize\uE202{"path":"D:/proj/tako/work/phone-control-review/phone-control-status.html"}\uE201';

String _reference(String path, {String? title}) =>
    '\uE200visualize\uE202${jsonEncode({'path': path, 'title': ?title, 'mode': 'wide'})}\uE201';

class _Client extends BridgeClient {
  _Client()
    : super(
        HostConfig(
          name: 'test',
          urls: ['wss://bridge.example/acp'],
          token: 'fixture',
          deviceId: 'test',
          deviceName: 'test',
        ),
      );

  String? readPath;
  RpcError? readError;

  @override
  Future<dynamic> request(String method, [Map<String, dynamic>? params]) async {
    expect(method, '_codeaw/fs/read');
    readPath = params!['path'] as String;
    if (readError case final error?) throw error;
    return {'binary': false, 'text': '<button>停止</button>', 'size': 29};
  }
}

Widget _wrap(Widget child) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: SelectionArea(child: child),
      ),
    ),
  ),
);

String _visibleText(WidgetTester tester) => tester
    .widgetList<RichText>(find.byType(RichText))
    .map((widget) => widget.text.toPlainText())
    .join('\n');

Future<void> _showRoute(
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
              source,
              client: client,
              basePath: r'D:\proj\codeaw',
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/file',
        builder: (_, route) =>
            FileViewPage(path: route.uri.queryParameters['path']!),
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
}

void main() {
  testWidgets('screenshot reference opens the bridge HTML file', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final client = _Client();
    await _showRoute(tester, client, '完成檢查。\n\n$_screenshotReference\n\n其餘內容。');
    expect(find.byType(MarkdownVisualization), findsOneWidget);
    expect(_visibleText(tester), contains('完成檢查。'));
    expect(_visibleText(tester), contains('其餘內容。'));
    expect(_visibleText(tester), isNot(contains('\uE200visualize')));
    expect(client.readPath, isNull);
    await tester.tap(find.text('phone-control-status.html'));
    await tester.pumpAndSettle();
    expect(
      client.readPath,
      r'D:\proj\tako\work\phone-control-review\phone-control-status.html',
    );
    expect(find.byType(FileViewPage), findsOneWidget);
    expect(find.byTooltip('下載檔案'), findsOneWidget);
    expect(find.byTooltip('分享檔案'), findsOneWidget);
    expect(
      tester.widget<CodeBlock>(find.byType(CodeBlock)).code,
      '<button>停止</button>',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('file titles and literal special characters survive routing', (
    tester,
  ) async {
    final client = _Client();
    const path = r'D:\proj\My Project\100% #1 畫面.html';
    const title = '畫面 [檢查](javascript:alert(1))';
    await _showRoute(tester, client, _reference(path, title: title));
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
    expect(client.readPath, path);
    expect(tester.widget<FileViewPage>(find.byType(FileViewPage)).path, path);
    expect(tester.takeException(), isNull);
  });

  testWidgets('denied file reads report the existing bridge error', (
    tester,
  ) async {
    final client = _Client()
      ..readError = RpcError(-32602, 'Path is outside the allowed workspaces');
    await _showRoute(tester, client, _reference('/outside/review.html'));
    await tester.tap(find.text('review.html'));
    await tester.pumpAndSettle();
    expect(find.text('Path is outside the allowed workspaces'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unfinished streamed references stay readable until complete', (
    tester,
  ) async {
    final client = _Client();
    addTearDown(client.dispose);
    for (final ending in ['\uE200vis', '\uE200visualize\uE202{"path":"D:/']) {
      await tester.pumpWidget(
        _wrap(Markdown('前段。\n\n$ending', streaming: true, client: client)),
      );
      expect(_visibleText(tester), contains('前段。'));
      expect(find.text('正在準備視覺化檔案…'), findsOneWidget);
      expect(_visibleText(tester), isNot(contains('\uE200')));
    }
    await tester.pumpWidget(
      _wrap(Markdown('前段。\n\n$_screenshotReference\n\n完成。', client: client)),
    );
    expect(find.text('正在準備視覺化檔案…'), findsNothing);
    expect(find.text('phone-control-status.html'), findsOneWidget);
    expect(_visibleText(tester), contains('完成。'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('references inside details appear when expanded', (tester) async {
    final client = _Client();
    addTearDown(client.dispose);
    await tester.pumpWidget(
      _wrap(
        Markdown(
          '<details>\n<summary>畫面</summary>\n\n$_screenshotReference\n</details>',
          client: client,
        ),
      ),
    );
    expect(find.byType(MarkdownVisualization), findsNothing);
    await tester.tap(find.byType(InkWell).first);
    await tester.pumpAndSettle();
    expect(find.byType(MarkdownDetails), findsOneWidget);
    expect(find.byType(MarkdownVisualization), findsOneWidget);
    expect(client.readPath, isNull);
    expect(tester.takeException(), isNull);
  });

  test('code examples, invalid JSON, and trailing prose stay literal', () {
    for (final source in [
      '```text\n$_screenshotReference\n```',
      '~~~\n$_screenshotReference\n~~~',
      '    $_screenshotReference',
      '\t$_screenshotReference',
      '`$_screenshotReference`',
      '前段 $_screenshotReference',
      '$_screenshotReference 後段',
      '\uE200visualize\uE202{"path":42}\uE201',
      '\uE200visualize\uE202{"title":"No path"}\uE201',
      '\uE200visualize\uE202{"path":""}\uE201',
      '\uE200visualize\uE202{"path":\uE201',
      '\uE200visualize\uE202{"path":"/file.html"}',
    ]) {
      final sections = splitMarkdownBlocks(source);
      expect(sections, hasLength(1), reason: source);
      expect(sections.single.text, source);
      expect(sections.single.node, isNull);
    }
  });

  test('multiple references and multiline JSON preserve message order', () {
    final sections = splitMarkdownBlocks(
      '前段\n$_screenshotReference\n中段\n'
      '\uE200visualize\uE202{\n"path":"/tmp/review.html",\n"title":"比較"\n}\uE201\n後段',
    );
    expect(sections.map((section) => section.line), [0, 1, 2, 3, 7]);
    expect(sections.map((section) => section.text), [
      '前段',
      null,
      '中段',
      null,
      '後段',
    ]);
    final reference = sections[3].node!.data as VisualizationReference;
    expect(reference.path, '/tmp/review.html');
    expect(reference.title, '比較');
  });

  test('file paths use the bridge OS and reject external schemes', () {
    expect(
      visualizationFilePath('work/review.html', basePath: r'D:\proj\codeaw'),
      r'D:\proj\codeaw\work\review.html',
    );
    expect(
      visualizationFilePath('../review.html', basePath: '/home/project'),
      '/home/review.html',
    );
    expect(
      visualizationFilePath('file:///D:/My%20Project/review.html'),
      r'D:\My Project\review.html',
    );
    expect(
      visualizationFilePath('/D:/proj/review.html'),
      r'D:\proj\review.html',
    );
    expect(
      visualizationFilePath(r'\\server\share\review.html'),
      r'\\server\share\review.html',
    );
    for (final source in [
      'relative.html',
      'https://example.com/review.html',
      '//example.com/review.html',
      'javascript:alert(1)',
      'data:text/html,<h1>Review</h1>',
      'file://[',
      '\u0000',
    ]) {
      expect(visualizationFilePath(source), isNull, reason: source);
    }
  });

  testWidgets(
    'unavailable and external references have disabled file actions',
    (tester) async {
      final client = _Client();
      addTearDown(client.dispose);
      for (final markdown in [
        const Markdown(_screenshotReference),
        Markdown(_reference('javascript:alert(1)'), client: client),
      ]) {
        await tester.pumpWidget(_wrap(markdown));
        expect(find.text('無法開啟視覺化檔案'), findsOneWidget);
        expect(
          tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
          isNull,
        );
        expect(client.readPath, isNull);
        expect(tester.takeException(), isNull);
      }
    },
  );
}
