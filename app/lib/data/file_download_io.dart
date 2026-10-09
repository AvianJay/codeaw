import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../acp/jsonrpc.dart';
import 'file_download.dart';

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
  final client = HttpClient()..autoUncompress = false;
  var finished = false;
  var timedOut = false;
  final timer = Timer(timeout, () {
    timedOut = true;
    client.close(force: true);
  });
  void checkActive() {
    checkDownloadCancelled(cancel);
    if (timedOut) throw TimeoutException('檔案下載逾時', timeout);
  }

  unawaited(
    cancel?.whenCancelled.then((_) {
      if (!finished) client.close(force: true);
    }),
  );
  Directory? directory;
  RandomAccessFile? sink;
  try {
    return await (() async {
      final request = await client.openUrl(body == null ? 'GET' : 'POST', uri);
      request.followRedirects = false;
      headers.forEach((key, value) => request.headers.set(key, value));
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.add(utf8.encode(body));
      }
      final response = await request.close();
      checkActive();
      if (response.statusCode != 200) {
        final bytes = await response.take(1).expand((chunk) => chunk).toList();
        throw FormatException(
          downloadError(
            response.statusCode,
            utf8.decode(bytes, allowMalformed: true),
          ),
        );
      }
      directory = await (await getTemporaryDirectory()).createTemp(
        'codeaw-download-',
      );
      checkActive();
      final filename = safeDownloadName(name);
      final file = File(p.join(directory!.path, filename));
      sink = await file.open(mode: FileMode.write);
      final total = response.contentLength >= 0 ? response.contentLength : null;
      var received = 0;
      onProgress?.call(0, total);
      await for (final chunk in response) {
        checkActive();
        await sink!.writeFrom(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      checkActive();
      if (total != null && received != total) {
        throw const FormatException('下載未完成，請重試');
      }
      await sink!.close();
      sink = null;
      checkActive();
      final downloadedDirectory = directory!;
      directory = null;
      return DownloadedFile(
        path: file.path,
        name: filename,
        size: received,
        mimeType:
            response.headers.contentType?.mimeType ??
            'application/octet-stream',
        dispose: () async {
          if (await downloadedDirectory.exists()) {
            await downloadedDirectory.delete(recursive: true);
          }
        },
      );
    })();
  } catch (_) {
    checkActive();
    rethrow;
  } finally {
    finished = true;
    timer.cancel();
    client.close(force: true);
    await sink?.close();
    if (directory != null && await directory!.exists()) {
      await directory!.delete(recursive: true);
    }
  }
}

Future<bool> saveDownload(DownloadedFile file) async {
  if (defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android) {
    return await FlutterFileDialog.saveFile(
          params: SaveFileDialogParams(
            sourceFilePath: file.path,
            fileName: file.name,
          ),
        ) !=
        null;
  }
  final location = await getSaveLocation(suggestedName: file.name);
  if (location == null) return false;
  await File(file.path).copy(location.path);
  return true;
}

Future<bool> shareDownload(DownloadedFile file, Rect origin) async {
  final result = await SharePlus.instance.share(
    ShareParams(
      files: [XFile(file.path, name: file.name, mimeType: file.mimeType)],
      fileNameOverrides: [file.name],
      sharePositionOrigin: origin,
    ),
  );
  return result.status != ShareResultStatus.dismissed;
}
