import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:file_selector/file_selector.dart';
import 'package:http/http.dart' as http;

import 'upload_progress.dart';

Future<http.Response> uploadBytes(
  Uri uri,
  Map<String, String> headers,
  Uint8List bytes, {
  UploadProgressCallback? onProgress,
  Duration timeout = uploadTimeout,
}) => _uploadStream(
  uri,
  headers,
  Stream.value(bytes),
  bytes.length,
  onProgress: onProgress,
  timeout: timeout,
);

Future<http.Response> uploadFile(
  Uri uri,
  Map<String, String> headers,
  XFile file,
  int length, {
  UploadProgressCallback? onProgress,
  Duration timeout = uploadTimeout,
}) => _uploadStream(
  uri,
  headers,
  file.openRead(),
  length,
  onProgress: onProgress,
  timeout: timeout,
);

Future<http.Response> _uploadStream(
  Uri uri,
  Map<String, String> headers,
  Stream<List<int>> source,
  int length, {
  UploadProgressCallback? onProgress,
  required Duration timeout,
}) async {
  final client = HttpClient();
  try {
    return await (() async {
      final request = await client.postUrl(uri);
      request.contentLength = length;
      request.bufferOutput = false;
      request.followRedirects = false;
      headers.forEach((key, value) => request.headers.set(key, value));
      onProgress?.call(0, length);
      const chunkSize = 64 * 1024;
      var sent = 0;
      await for (final chunk in source) {
        final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
        if (sent + bytes.length > length) {
          throw const FormatException('檔案大小在上傳期間變更，請重新選取');
        }
        for (var offset = 0; offset < bytes.length; offset += chunkSize) {
          final end = (offset + chunkSize).clamp(0, bytes.length);
          request.add(Uint8List.sublistView(bytes, offset, end));
          // Read the next file chunk only after the transport accepts this one.
          await request.flush();
          sent += end - offset;
          onProgress?.call(sent, length);
        }
      }
      if (sent != length) {
        throw const FormatException('檔案大小在上傳期間變更，請重新選取');
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
