import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/app_updater.dart';

const _installer = MethodChannel('codeaw/app_updater');

/// Streams into private cache, verifies the release checksum, then grants the
/// system installer temporary access through the Android FileProvider.
Future<void> downloadAndInstallApk(
  UpdateAsset asset,
  void Function(double progress) onProgress,
) async {
  if (!Platform.isAndroid) {
    throw const UpdateException('此平台不支援 APK 安裝');
  }
  await _installer.invokeMethod<void>('requestInstallPermission');
  final directory = Directory(
    p.join((await getTemporaryDirectory()).path, 'updates'),
  );
  await directory.create(recursive: true);
  final file = File(p.join(directory.path, 'codeaw-update.apk'));
  final client = http.Client();
  try {
    await downloadVerifiedApk(client, asset, file, onProgress);
    await _installer.invokeMethod<void>('installApk', {'path': file.path});
  } catch (_) {
    if (await file.exists()) await file.delete();
    rethrow;
  } finally {
    client.close();
  }
}

/// Kept separate so interrupted downloads and checksum failures can be tested
/// without opening the Android installer.
Future<void> downloadVerifiedApk(
  http.Client client,
  UpdateAsset asset,
  File file,
  void Function(double progress) onProgress,
) async {
  final partial = File('${file.path}.part');
  IOSink? sink;
  try {
    final response = await client
        .send(http.Request('GET', asset.url))
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw const UpdateException('APK 下載失敗，請稍後重試');
    }
    sink = partial.openWrite();
    var received = 0;
    onProgress(0);
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 30),
    )) {
      received += chunk.length;
      if (received > asset.size) {
        throw const UpdateException('APK 大小與更新資訊不符，請重新檢查更新');
      }
      sink.add(chunk);
      // Flush each chunk to bound memory even on a fast network / slow storage.
      await sink.flush();
      onProgress(received / asset.size);
    }
    await sink.close();
    sink = null;
    if (received != asset.size ||
        (await sha256.bind(partial.openRead()).first).toString() !=
            asset.sha256) {
      throw const UpdateException('APK 驗證失敗，請重新檢查更新後再下載');
    }
    await partial.rename(file.path);
  } finally {
    await sink?.close();
    if (await partial.exists()) await partial.delete();
  }
}
