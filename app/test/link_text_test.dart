import 'package:codeaw/data/timeline.dart';
import 'package:codeaw/ui/chat/items.dart';
import 'package:codeaw/ui/common/link_text.dart';
import 'package:codeaw/ui/common/markdown.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/custom_widgets/inline_tap.dart';

/// The log line from the bug report: a pasted error with two Markdown links in it.
const _log =
    'WARNING | Gemini native HTTP 400: {"message":"You can '
    '[send feedback](https://aistudio.google.com/docs/troubleshooting#file-bug) or read more about '
    '[our policies here](https://policies.google.com/terms/generative-ai/use-policy).","param":null}';

TextSpan _link(WidgetTester tester, String label) {
  TextSpan? found;
  for (final text in tester.widgetList<RichText>(find.byType(RichText))) {
    text.text.visitChildren((span) {
      if (span is TextSpan && span.text == label && span.recognizer != null) {
        found = span;
      }
      return found == null;
    });
  }
  return found!;
}

void main() {
  tearDown(() => debugLinkLauncher = null);

  test('finds the web links in text that was never Markdown', () {
    expect(linkRuns(_log).where((run) => run.url != null).toList(), [
      (
        text: 'send feedback',
        url: 'https://aistudio.google.com/docs/troubleshooting#file-bug',
      ),
      (
        text: 'our policies here',
        url: 'https://policies.google.com/terms/generative-ai/use-policy',
      ),
    ]);
    // Nothing but the link syntax is dropped from the text.
    expect(
      linkRuns(_log).map((run) => run.text).join(),
      _log
          .replaceAll(RegExp(r'\]\(https?://[^)]*\)'), '')
          .replaceAll('[send', 'send')
          .replaceAll('[our', 'our'),
    );

    String? only(String text) =>
        linkRuns(text).where((run) => run.url != null).single.url;
    expect(only('看 https://example.com/a?b=1&c=2。然後'), 'https://example.com/a?b=1&c=2');
    expect(only('(see https://example.com/x).'), 'https://example.com/x');
    expect(
      only('https://en.wikipedia.org/wiki/Dart_(programming_language), ok'),
      'https://en.wikipedia.org/wiki/Dart_(programming_language)',
    );
    expect(only('[t](https://example.com "Title")'), 'https://example.com');
    expect(only('**https://example.com/b**'), 'https://example.com/b');
    expect(only('or www.example.com/h.'), 'https://www.example.com/h');
    expect(linkRuns('mail a@www.example.com or awww.x.y').every((run) => run.url == null), isTrue);
    for (final plain in ['no links', 'a [b] (c)', 'http:// nothing', 'x[1](2)']) {
      expect(linkRuns(plain), [(text: plain, url: null)], reason: plain);
    }
    expect(linkRuns(''), isEmpty);
  });

  test('a link target is read without its wrapper or title', () {
    expect(linkTarget('https://example.com "Title here"'), 'https://example.com');
    expect(linkTarget("<https://example.com/a b> 'T'"), 'https://example.com/a b');
    expect(
      linkTarget('<E:/Projects/Wallpaper Engine iOS/lib/main.dart:12>'),
      'E:/Projects/Wallpaper Engine iOS/lib/main.dart:12',
    );
    expect(
      linkTarget('E:/Projects/Wallpaper Engine iOS/lib/main.dart:12'),
      'E:/Projects/Wallpaper Engine iOS/lib/main.dart:12',
    );
  });

  testWidgets('links in a sent message open instead of showing as raw syntax', (
    tester,
  ) async {
    final opened = <Uri>[];
    debugLinkLauncher = (uri) async {
      opened.add(uri);
      return true;
    };
    final m = MessageItem('m1', MessageRole.user, 'u1')
      ..parts.add({'type': 'text', 'text': _log});
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: UserMessageView(m))),
    );
    final shown = tester
        .widgetList<RichText>(find.byType(RichText))
        .map((text) => text.text.toPlainText(includeSemanticsLabels: false))
        .join();
    expect(shown, contains('You can send feedback or read more about our policies here.'));
    expect(shown, isNot(contains('](')));

    (_link(tester, 'send feedback').recognizer! as TapGestureRecognizer).onTap!();
    (_link(tester, 'our policies here').recognizer! as TapGestureRecognizer).onTap!();
    await tester.pump();
    expect(opened.map((uri) => '$uri'), [
      'https://aistudio.google.com/docs/troubleshooting#file-bug',
      'https://policies.google.com/terms/generative-ai/use-policy',
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a link nothing can open says so', (tester) async {
    debugLinkLauncher = (uri) async => false;
    final m = MessageItem('m1', MessageRole.user, 'u1')
      ..parts.add({'type': 'text', 'text': 'go https://example.com/x now'});
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: UserMessageView(m))),
    );
    await tester.tap(find.textContaining('https://example.com/x', findRichText: true));
    await tester.pump();
    expect(find.text('無法開啟這個連結'), findsOneWidget);
  });

  testWidgets('agent links with a title, a mail address or a bare host open', (
    tester,
  ) async {
    final opened = <String>[];
    debugLinkLauncher = (uri) async {
      opened.add('$uri');
      return true;
    };
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Markdown(
            '[titled](https://example.com/t "Title") · [mail](mailto:a@example.com) · [host](www.example.com/h)',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final links = <LinkTextSpan>[];
    // visitChildren skips a span that only wraps children, which a link is.
    void walk(InlineSpan span) {
      if (span is LinkTextSpan) links.add(span);
      if (span is TextSpan) span.children?.forEach(walk);
    }

    // The package paints with a RichText subclass, which byType does not match.
    for (final widget in tester.allWidgets) {
      if (widget is RichText) walk(widget.text);
    }
    for (final link in links) {
      link.onTap!();
      await tester.pump();
    }
    expect(opened, [
      'https://example.com/t',
      'mailto:a@example.com',
      'https://www.example.com/h',
    ]);
    expect(find.text('無法開啟這個連結'), findsNothing);
  });
}
