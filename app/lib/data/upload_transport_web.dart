import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

import 'upload_progress.dart';

Future<http.Response> uploadBytes(
  Uri uri,
  Map<String, String> headers,
  Uint8List bytes, {
  UploadProgressCallback? onProgress,
  Duration timeout = const Duration(minutes: 2),
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
    onProgress?.call(loaded.clamp(0, bytes.length), bytes.length);
  }).toJS;
  request.upload.onload = ((web.Event _) {
    if (!done.isCompleted) onProgress?.call(bytes.length, bytes.length);
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
  onProgress?.call(0, bytes.length);
  request.send(bytes.toJS);
  return done.future;
}
