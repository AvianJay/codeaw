import 'package:flutter/foundation.dart';
import 'package:pasteboard/pasteboard.dart';

import 'image_clipboard.dart';

ImageClipboard createImageClipboard() => _NativeImageClipboard();

class _NativeImageClipboard implements ImageClipboard {
  @override
  bool get usesPasteEvents => false;

  @override
  Future<ImagePaste> read() async {
    final bytes = await Pasteboard.image;
    if (bytes == null || bytes.isEmpty) return const ImagePaste();
    return ImagePaste(images: [ClipboardImage.fromBytes(bytes)]);
  }

  @override
  VoidCallback listen({
    required bool Function() canPaste,
    required void Function(Future<ImagePaste>) onPaste,
  }) => () {};
}
