import 'package:flutter/foundation.dart';

import 'image_clipboard_native.dart'
    if (dart.library.js_interop) 'image_clipboard_web.dart'
    as platform;

class ClipboardImage {
  const ClipboardImage(this.bytes, this.mimeType);
  final Uint8List bytes;
  final String mimeType;

  static const mimeTypes = [
    'image/png',
    'image/jpeg',
    'image/webp',
    'image/gif',
  ];

  factory ClipboardImage.fromBytes(Uint8List bytes) {
    final String mime;
    if (bytes.length >= 8 &&
        listEquals(bytes.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10])) {
      mime = 'image/png';
    } else if (bytes.length >= 3 &&
        bytes[0] == 255 &&
        bytes[1] == 216 &&
        bytes[2] == 255) {
      mime = 'image/jpeg';
    } else if (bytes.length >= 6 &&
        String.fromCharCodes(bytes.sublist(0, 6)).startsWith('GIF8')) {
      mime = 'image/gif';
    } else if (bytes.length >= 12 &&
        String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
        String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP') {
      mime = 'image/webp';
    } else {
      throw const FormatException('Unsupported clipboard image');
    }
    return ClipboardImage(bytes, mime);
  }
}

class ImagePaste {
  const ImagePaste({this.images = const [], this.text = ''});
  final List<ClipboardImage> images;
  final String text;
}

/// Clipboard reads only happen in response to an explicit paste action.
abstract class ImageClipboard {
  factory ImageClipboard() => platform.createImageClipboard();
  bool get usesPasteEvents;
  Future<ImagePaste> read();
  VoidCallback listen({
    required bool Function() canPaste,
    required void Function(Future<ImagePaste> paste) onPaste,
  });
}
