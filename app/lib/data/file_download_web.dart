import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui';

import 'package:web/web.dart' as web;

import '../acp/jsonrpc.dart';
import 'file_download.dart';

final _blobs = <String, web.Blob>{};

Future<DownloadedFile> fetchDownload(
  Uri uri,
  Map<String, String> headers, {
  required String name,
  String? body,
  DownloadProgress? onProgress,
  CancelToken? cancel,
  Duration timeout = downloadTimeout,
}) async {
  checkDownloadCancelled(cancel);
  final done = Completer<DownloadedFile>();
  final request = web.XMLHttpRequest();
  request.open(body == null ? 'GET' : 'POST', uri.toString());
  request.responseType = 'blob';
  request.timeout = timeout.inMilliseconds;
  headers.forEach((name, value) => request.setRequestHeader(name, value));
  if (body != null) {
    request.setRequestHeader('Content-Type', 'application/json');
  }
  unawaited(
    cancel?.whenCancelled.then((_) {
      if (!done.isCompleted) request.abort();
    }),
  );
  request.onprogress = ((web.Event event) {
    final progress = event as web.ProgressEvent;
    if (!done.isCompleted) {
      onProgress?.call(
        progress.loaded.toInt(),
        progress.lengthComputable ? progress.total.toInt() : null,
      );
    }
  }).toJS;
  request.onload = ((web.Event _) {
    if (done.isCompleted) return;
    final blob = request.response as web.Blob;
    if (request.status != 200) {
      unawaited(
        blob.text().toDart.then((text) {
          if (!done.isCompleted) {
            done.completeError(
              FormatException(downloadError(request.status, text.toDart)),
            );
          }
        }),
      );
      return;
    }
    final url = web.URL.createObjectURL(blob);
    _blobs[url] = blob;
    onProgress?.call(blob.size, blob.size);
    done.complete(
      DownloadedFile(
        path: url,
        name: safeDownloadName(name),
        size: blob.size,
        mimeType: blob.type.isEmpty ? 'application/octet-stream' : blob.type,
        dispose: () async {
          _blobs.remove(url);
          web.URL.revokeObjectURL(url);
        },
      ),
    );
  }).toJS;
  request.onerror = ((web.Event _) {
    if (!done.isCompleted) {
      done.completeError(const FormatException('連線中斷，下載失敗，請重試'));
    }
  }).toJS;
  request.ontimeout = ((web.Event _) {
    if (!done.isCompleted) done.completeError(TimeoutException('檔案下載逾時'));
  }).toJS;
  request.onabort = ((web.Event _) {
    if (!done.isCompleted) done.completeError(DownloadCancelled());
  }).toJS;
  onProgress?.call(0, null);
  request.send(body?.toJS);
  return done.future;
}

Future<bool> saveDownload(DownloadedFile file) async {
  final anchor = web.HTMLAnchorElement()
    ..href = file.path
    ..download = file.name;
  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  // Let the browser acquire the Blob before the dialog revokes its object URL.
  await Future<void>.delayed(const Duration(seconds: 1));
  return true;
}

/// Called from the ready dialog's button so Web Share retains user activation.
Future<bool> shareDownload(DownloadedFile file, Rect origin) {
  final blob = _blobs[file.path]!;
  final data = web.ShareData(
    files: [
      web.File(
        [blob].toJS,
        file.name,
        web.FilePropertyBag(type: file.mimeType),
      ),
    ].toJS,
  );
  final navigator = web.window.navigator;
  if (!navigator.hasProperty('share'.toJS).toDart ||
      !navigator.hasProperty('canShare'.toJS).toDart ||
      !navigator.canShare(data)) {
    return Future.error(const FormatException('這個瀏覽器不支援檔案分享，請選擇「儲存檔案」'));
  }
  return navigator
      .share(data)
      .toDart
      .then(
        (_) => true,
        onError: (Object error) {
          if ((error as JSAny).isA<web.DOMException>() &&
              (error as web.DOMException).name == 'AbortError') {
            return false;
          }
          throw const FormatException('無法開啟分享選單，請選擇「儲存檔案」');
        },
      );
}
