import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import 'image_clipboard.dart';

ImageClipboard createImageClipboard() => _WebImageClipboard();

class _WebImageClipboard implements ImageClipboard {
  @override
  bool get usesPasteEvents => true;

  @override
  VoidCallback listen({
    required bool Function() canPaste,
    required void Function(Future<ImagePaste>) onPaste,
  }) {
    final listener = ((web.Event event) {
      if (!canPaste()) return;
      final data = (event as web.ClipboardEvent).clipboardData;
      if (data == null) return;
      // Capture File objects while the browser's clipboard data is accessible.
      final files = <web.File>[];
      for (var i = 0; i < data.files.length; i++) {
        final file = data.files.item(i);
        if (file != null && ClipboardImage.mimeTypes.contains(file.type)) {
          files.add(file);
        }
      }
      if (files.isEmpty) return; // Let Flutter handle ordinary text paste.
      event.preventDefault();
      final text = data.getData('text/plain');
      onPaste(_readFiles(files, text));
    }).toJS;
    web.document.addEventListener('paste', listener, true.toJS);
    return () => web.document.removeEventListener('paste', listener, true.toJS);
  }

  Future<ImagePaste> _readFiles(List<web.File> files, String text) async =>
      ImagePaste(images: await Future.wait(files.map(_readBlob)), text: text);

  Future<ClipboardImage> _readBlob(web.Blob blob) async {
    final buffer = await blob.arrayBuffer().toDart;
    return ClipboardImage.fromBytes(buffer.toDart.asUint8List());
  }

  @override
  Future<ImagePaste> read() async {
    final items = (await web.window.navigator.clipboard.read().toDart).toDart;
    final images = <ClipboardImage>[];
    for (final item in items) {
      final types = item.types.toDart
          .map((type) => type.toDart)
          .where(ClipboardImage.mimeTypes.contains)
          .toList();
      if (types.isEmpty) continue;
      final type = types.contains('image/png') ? 'image/png' : types.first;
      images.add(await _readBlob(await item.getType(type).toDart));
    }
    return ImagePaste(images: images);
  }
}
