import 'dart:convert';
import 'dart:ui' as ui;

import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/session_controller.dart';
import 'package:codeaw/data/timeline.dart';
import 'package:codeaw/ui/chat/items.dart';
import 'package:codeaw/ui/common/code_view.dart';
import 'package:codeaw/ui/common/markdown.dart';
import 'package:codeaw/ui/common/markdown_details.dart';
import 'package:codeaw/ui/common/markdown_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGPgn9v1HwAEKwI2+WpYHgAAAABJRU5ErkJggg==';

Future<String> _phoneImage() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(const Color(0xFF11221E), BlendMode.src);
  final paint = Paint()..color = const Color(0xFF0F9D8A);
  canvas.drawRect(const Rect.fromLTWH(32, 60, 656, 80), paint);
  paint.color = const Color(0xFFBED3CC);
  for (var y = 220.0; y < 1400; y += 100) {
    canvas.drawRect(Rect.fromLTWH(32, y, 520, 24), paint);
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(720, 1600);
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
  final result = base64Encode(bytes.buffer.asUint8List());
  image.dispose();
  picture.dispose();
  return result;
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

BridgeClient _client() => BridgeClient(
  HostConfig(
    name: 'test',
    urls: ['wss://bridge.example/acp'],
    token: 'test-token',
    deviceId: 'test',
    deviceName: 'test',
  ),
);

String _visibleText(WidgetTester tester) => tester
    .widgetList<RichText>(find.byType(RichText))
    .map((w) => w.text.toPlainText())
    .join('\n');

void main() {
  test('resolves bridge paths independently of the client OS', () {
    expect(
      markdownImagePath(
        'app/test/screenshots/phone.png',
        basePath: r'D:\proj\codeaw',
      ),
      r'D:\proj\codeaw\app\test\screenshots\phone.png',
    );
    expect(
      markdownImagePath(
        '../images/phone%20dark.png',
        basePath: '/home/project/docs',
      ),
      '/home/project/images/phone dark.png',
    );
    expect(
      markdownImagePath(r'D:\proj\codeaw\phone.png'),
      r'D:\proj\codeaw\phone.png',
    );
    expect(
      markdownImagePath('D:/proj/codeaw/phone%20dark.png'),
      r'D:\proj\codeaw\phone dark.png',
    );
    expect(
      markdownImagePath('/D:/proj/codeaw/phone.png'),
      r'D:\proj\codeaw\phone.png',
    );
    expect(
      markdownImagePath('file:///D:/proj/codeaw/phone%20dark.png'),
      r'D:\proj\codeaw\phone dark.png',
    );
    expect(
      markdownImagePath('file:///home/project/phone.png'),
      '/home/project/phone.png',
    );
    expect(
      markdownImagePath('/home/project/phone.png'),
      '/home/project/phone.png',
    );
    expect(
      markdownImagePath(r'\\server\share\phone.png'),
      r'\\server\share\phone.png',
    );
    expect(markdownImagePath('phone.png'), isNull);
    expect(
      markdownImagePath(
        'https://example.com/phone.png',
        basePath: '/home/project',
      ),
      isNull,
    );
  });

  test(
    'authenticates local images and blobs without sending credentials to remote images',
    () {
      final client = _client();
      addTearDown(client.dispose);
      final local =
          markdownImageProvider(
                'phone.png',
                client: client,
                basePath: r'D:\proj\codeaw',
              )
              as NetworkImage;
      expect(Uri.parse(local.url).host, 'bridge.example');
      expect(Uri.parse(local.url).path, '/api/fs/raw');
      expect(
        Uri.parse(local.url).queryParameters['path'],
        r'D:\proj\codeaw\phone.png',
      );
      expect(local.headers, client.authHeaders);
      final blob =
          markdownImageProvider('codeaw-blob:${'a' * 64}', client: client)
              as NetworkImage;
      expect(Uri.parse(blob.url).path, '/api/blobs/${'a' * 64}');
      expect(blob.headers, client.authHeaders);
      final remote =
          markdownImageProvider('https://example.com/phone.png', client: client)
              as NetworkImage;
      expect(remote.url, 'https://example.com/phone.png');
      expect(remote.headers, isNull);
      final inline =
          markdownImageProvider('data:image/png;base64,$_png') as MemoryImage;
      expect(inline.bytes, base64Decode(_png));
      expect(
        markdownImageProvider('javascript:alert(1)', client: client),
        isNull,
      );
      expect(markdownImageProvider('file://[', client: client), isNull);
      expect(
        markdownImageProvider('file:///phone.png?query', client: client),
        isNull,
      );
      expect(markdownImageProvider('data:text/html;base64,PGgxPg=='), isNull);
    },
  );

  testWidgets('details hide tags and defer images until expanded on a phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final phoneImage = (await tester.runAsync(_phoneImage))!;
    await tester.pumpWidget(
      _wrap(
        Markdown('''
Web build 已完成。

<details>
<summary>手機尺寸實測畫面</summary>

![phone](data:image/png;base64,$phoneImage)

畫面說明。
</details>

其餘內容。
'''),
      ),
    );
    expect(find.byType(MarkdownDetails), findsOneWidget);
    expect(_visibleText(tester), contains('手機尺寸實測畫面'));
    expect(_visibleText(tester), isNot(contains('<details>')));
    expect(find.byType(MarkdownImage), findsNothing);
    expect(_visibleText(tester), isNot(contains('畫面說明')));
    await tester.tap(find.byType(InkWell).first);
    await tester.pump();
    await tester.runAsync(
      () => precacheImage(
        MemoryImage(base64Decode(phoneImage)),
        tester.element(find.byType(MarkdownImage)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(MarkdownImage), findsOneWidget);
    expect(_visibleText(tester), contains('畫面說明'));
    expect(_visibleText(tester), contains('其餘內容'));
    expect(tester.takeException(), isNull);
    final image = find.byType(Image);
    expect(tester.getSize(image).width, lessThanOrEqualTo(304));
    expect(tester.getSize(image).height, 360);
    await tester.tap(image);
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await tester.tap(find.byTooltip('關閉'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(InkWell).first);
    await tester.pumpAndSettle();
    expect(find.byType(MarkdownImage), findsNothing);
  });

  testWidgets(
    'expanded streaming details retain their state as tokens arrive',
    (tester) async {
      await tester.pumpWidget(
        _wrap(
          const Markdown(
            '<details>\n<summary>畫面</summary>\n\n第一段',
            streaming: true,
          ),
        ),
      );
      await tester.tap(find.byType(InkWell).first);
      await tester.pumpAndSettle();
      expect(_visibleText(tester), contains('第一段'));
      await tester.pumpWidget(
        _wrap(
          const Markdown(
            '<details>\n<summary>畫面</summary>\n\n第一段\n\n第二段\n</details>',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_visibleText(tester), contains('第二段'));
      expect(_visibleText(tester), isNot(contains('</details>')));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'supports open and nested details while preserving code examples',
    (tester) async {
      await tester.pumpWidget(
        _wrap(
          const Markdown('''
<details open><summary>外層</summary>
`</details>` is code.

```html
</details>
<details><summary>範例</summary></details>
```

<details><summary>內層</summary>
內層內容
</details>
</details>
'''),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MarkdownDetails), findsNWidgets(2));
      expect(_visibleText(tester), contains('外層'));
      expect(_visibleText(tester), contains('內層'));
      expect(_visibleText(tester), isNot(contains('內層內容')));
      await tester.tap(find.byType(InkWell).last);
      await tester.pumpAndSettle();
      expect(_visibleText(tester), contains('內層內容'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('details examples inside a code fence stay literal', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const Markdown(
          '```html\n<details>\n<summary>範例</summary>\n</details>\n```',
        ),
      ),
    );
    expect(find.byType(MarkdownDetails), findsNothing);
    expect(
      tester.widget<CodeBlock>(find.byType(CodeBlock)).code,
      contains('<details>'),
    );
  });

  testWidgets('sections with identical titles keep independent expansion state', (
    tester,
  ) async {
    const sections =
        '<details>\n<summary>畫面</summary>\n第一張\n</details>\n\n<details>\n<summary>畫面</summary>\n第二張\n</details>';
    await tester.pumpWidget(_wrap(const Markdown(sections, streaming: true)));
    await tester.tap(find.byType(InkWell).first);
    await tester.pumpAndSettle();
    expect(_visibleText(tester), contains('第一張'));
    expect(_visibleText(tester), isNot(contains('第二張')));
    await tester.pumpWidget(_wrap(const Markdown('$sections\n\n完成')));
    await tester.pumpAndSettle();
    expect(_visibleText(tester), contains('第一張'));
    expect(_visibleText(tester), isNot(contains('第二張')));
  });

  testWidgets('indented code does not close a details block', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const Markdown(
          '<details open>\n<summary>範例</summary>\n\n    </details>\n\n結尾內容\n</details>',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(MarkdownDetails), findsOneWidget);
    final details = tester.widget<MarkdownDetails>(
      find.byType(MarkdownDetails),
    );
    expect(details.node.body, contains('    </details>'));
    expect(_visibleText(tester), contains('結尾內容'));
  });

  testWidgets('chat passes the session cwd and bridge to Markdown', (
    tester,
  ) async {
    final client = _client();
    final controller = SessionController(
      client,
      'codex:test',
      cwd: r'D:\proj\codeaw',
    );
    addTearDown(controller.dispose);
    addTearDown(client.dispose);
    final message = MessageItem('m', MessageRole.agent, 'm')
      ..parts.add({'type': 'text', 'text': '完成'});
    await tester.pumpWidget(
      _wrap(
        TimelineItemView(item: message, controller: controller, isLast: true),
      ),
    );
    final markdown = tester.widget<Markdown>(find.byType(Markdown));
    expect(markdown.client, same(client));
    expect(markdown.basePath, controller.cwd);
  });

  testWidgets('an unsupported image displays a compact failure message', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(const Markdown('![image](ftp://example.com/image.png)')),
    );
    expect(find.text('無法載入圖片'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(find.byType(GptMarkdown), findsOneWidget);
  });
}
