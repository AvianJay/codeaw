@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:codeaw/util/image_clipboard.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
);

web.ClipboardEvent _event({int images = 1, String text = ''}) {
  final data = web.DataTransfer();
  if (text.isNotEmpty) data.setData('text/plain', text);
  for (var i = 0; i < images; i++) {
    data.items.add(
      web.File(
        [_png.toJS].toJS,
        'image-$i.png',
        web.FilePropertyBag(type: 'image/png'),
      ),
    );
  }
  return web.ClipboardEvent(
    'paste',
    web.ClipboardEventInit(
      clipboardData: data,
      bubbles: true,
      cancelable: true,
    ),
  );
}

void main() {
  test(
    'browser paste reads multiple images and text directly from the paste event',
    () async {
      final clipboard = ImageClipboard();
      expect(clipboard.usesPasteEvents, isTrue);
      final pasted = Completer<ImagePaste>();
      final stop = clipboard.listen(
        canPaste: () => true,
        onPaste: pasted.complete,
      );
      addTearDown(stop);
      final event = _event(images: 2, text: 'describe these images');
      web.document.dispatchEvent(event);
      expect(event.defaultPrevented, isTrue);
      final data = await pasted.future;
      expect(data.text, 'describe these images');
      expect(data.images, hasLength(2));
      for (final image in data.images) {
        expect(image.mimeType, 'image/png');
        expect(image.bytes, _png);
      }
    },
  );

  test('text-only paste keeps the browser default action', () {
    final clipboard = ImageClipboard();
    var called = false;
    final stop = clipboard.listen(
      canPaste: () => true,
      onPaste: (_) => called = true,
    );
    addTearDown(stop);
    final event = _event(images: 0, text: 'ordinary text');
    web.document.dispatchEvent(event);
    expect(event.defaultPrevented, isFalse);
    expect(called, isFalse);
  });

  test('inactive or unsupported composers never intercept paste', () {
    final clipboard = ImageClipboard();
    var called = false;
    final stop = clipboard.listen(
      canPaste: () => false,
      onPaste: (_) => called = true,
    );
    addTearDown(stop);
    final event = _event();
    web.document.dispatchEvent(event);
    expect(event.defaultPrevented, isFalse);
    expect(called, isFalse);
  });

  test('disposing the listener restores the browser paste behavior', () {
    final clipboard = ImageClipboard();
    var called = false;
    final stop = clipboard.listen(
      canPaste: () => true,
      onPaste: (_) => called = true,
    );
    stop();
    final event = _event();
    web.document.dispatchEvent(event);
    expect(event.defaultPrevented, isFalse);
    expect(called, isFalse);
  });
}
