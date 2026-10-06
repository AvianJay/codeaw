import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'upload_progress.dart';

Future<http.Response> uploadBytes(
  Uri uri,
  Map<String, String> headers,
  Uint8List bytes, {
  UploadProgressCallback? onProgress,
  Duration timeout = const Duration(minutes: 2),
}) async {
  final client = HttpClient();
  try {
    return await (() async {
      final request = await client.postUrl(uri);
      request.contentLength = bytes.length;
      request.bufferOutput = false;
      request.followRedirects = false;
      headers.forEach((key, value) => request.headers.set(key, value));
      onProgress?.call(0, bytes.length);
      const chunkSize = 64 * 1024;
      for (var offset = 0; offset < bytes.length; offset += chunkSize) {
        final end = (offset + chunkSize).clamp(0, bytes.length);
        request.add(Uint8List.sublistView(bytes, offset, end));
        // Respect transport backpressure rather than counting an in-memory copy.
        await request.flush();
        onProgress?.call(end, bytes.length);
      }
      final response = await request.close();
      final body = await consolidateHttpClientResponseBytes(response);
      final responseHeaders = <String, String>{};
      response.headers.forEach((key, values) {
        responseHeaders[key] = values.join(', ');
      });
      return http.Response.bytes(
        body,
        response.statusCode,
        headers: responseHeaders,
      );
    })().timeout(timeout);
  } finally {
    // Also abort an in-flight request after timeout or a transport failure.
    client.close(force: true);
  }
}
