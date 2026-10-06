import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:file_selector/file_selector.dart';
import 'package:web/web.dart' as web;

import 'upload_progress.dart';

Future<http.Response> uploadBytes(
  Uri uri,
  Map<String, String> headers,
  Uint8List bytes, {
  UploadProgressCallback? onProgress,
  Duration timeout = uploadTimeout,
}) => _uploadBody(
  uri,
  headers,
  bytes.toJS,
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
}) async {
  // The picker returns an object URL. Keep its Blob in browser storage instead
  // of converting the whole file into a Dart and then a JavaScript byte array.
  if (!file.path.startsWith('blob:')) {
    throw const FormatException('無法讀取選取的檔案，請重新選取');
  }
  final response = await web.window
      .fetch(file.path.toJS)
      .toDart
      .timeout(const Duration(minutes: 2));
  if (!response.ok) throw const FormatException('無法讀取選取的檔案');
  final blob = await response.blob().toDart.timeout(const Duration(minutes: 2));
  if (blob.size != length) {
    throw const FormatException('檔案大小在上傳期間變更，請重新選取');
  }
  return _uploadBody(
    uri,
    headers,
    blob,
    length,
    onProgress: onProgress,
    timeout: timeout,
  );
}

Future<http.Response> _uploadBody(
  Uri uri,
  Map<String, String> headers,
  JSAny body,
  int length, {
  UploadProgressCallback? onProgress,
  required Duration timeout,
}) async {
  final done = Completer<http.Response>();
  final request = web.XMLHttpRequest();
  request.open('POST', uri.toString());
  request.responseType = 'arraybuffer';
  request.timeout = timeout.inMilliseconds;
  headers.forEach((name, value) => request.setRequestHeader(name, value));
  request.upload.onprogress = ((web.Event event) {
    if (done.isCompleted) return;
    final loaded = (event as web.ProgressEvent).loaded.toInt();
    onProgress?.call(loaded.clamp(0, length), length);
  }).toJS;
  request.upload.onload = ((web.Event _) {
    if (!done.isCompleted) onProgress?.call(length, length);
  }).toJS;
  request.onload = ((web.Event _) {
    if (done.isCompleted) return;
    final body = request.response == null
        ? Uint8List(0)
        : (request.response as JSArrayBuffer).toDart.asUint8List();
    final responseHeaders = <String, String>{};
    for (final line in request.getAllResponseHeaders().split('\r\n')) {
      final separator = line.indexOf(':');
      if (separator > 0) {
        responseHeaders[line.substring(0, separator).trim().toLowerCase()] =
            line.substring(separator + 1).trim();
      }
    }
    done.complete(
      http.Response.bytes(body, request.status, headers: responseHeaders),
    );
  }).toJS;
  request.onerror = ((web.Event _) {
    if (!done.isCompleted) {
      done.completeError(http.ClientException('無法連線到電腦，上傳失敗'));
    }
  }).toJS;
  request.ontimeout = ((web.Event _) {
    if (!done.isCompleted) done.completeError(TimeoutException('檔案上傳逾時'));
  }).toJS;
  request.onabort = ((web.Event _) {
    if (!done.isCompleted) {
      done.completeError(http.ClientException('檔案上傳已中止'));
    }
  }).toJS;
  onProgress?.call(0, length);
  request.send(body);
  return done.future;
}
