import 'dart:convert';

import 'bridge_frame_web.dart'
    if (dart.library.io) 'bridge_frame_io.dart'
    as platform;

/// Text JSON from older bridges, or an explicitly negotiated binary gzip frame.
String decodeBridgeFrame(Object data) {
  if (data is String) return data;
  final bytes = (data as List).cast<int>();
  if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
    if (bytes.length < 18 || bytes[2] != 8) {
      throw const FormatException('Invalid compressed bridge frame');
    }
    return utf8.decode(platform.inflate(bytes));
  }
  return utf8.decode(bytes);
}
