import 'dart:async';
import 'dart:convert';

import '../acp/jsonrpc.dart';

typedef DownloadProgress = void Function(int received, int? total);
const downloadTimeout = Duration(hours: 1);

class DownloadCancelled implements Exception {}

/// A temporary native file or browser Blob URL, never a path on the bridge PC.
class DownloadedFile {
  const DownloadedFile({
    required this.path,
    required this.name,
    required this.size,
    required this.mimeType,
    required this.dispose,
  });
  final String path;
  final String name;
  final int size;
  final String mimeType;
  final Future<void> Function() dispose;
}

String safeDownloadName(String name) {
  final base = name.split(RegExp(r'[\\/]')).last;
  final safe = base
      .replaceAll(RegExp(r'[<>:"|?*\x00-\x1f\x7f]'), '_')
      .replaceAll(RegExp(r'[. ]+$'), '');
  return safe.isEmpty || safe == '.' || safe == '..' ? 'download' : safe;
}

String downloadError(int status, String body) {
  if (status == 404) return '檔案不存在；ZIP 功能請先更新電腦端 bridge';
  try {
    final json = jsonDecode(body);
    if (json is Map && json['error'] is String) return json['error'] as String;
  } catch (_) {}
  return '下載失敗（HTTP $status）';
}

void checkDownloadCancelled(CancelToken? cancel) {
  if (cancel?.isCancelled == true) throw DownloadCancelled();
}
