import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'history_storage.dart';

HistoryStorage createHistoryStorage() => FileHistoryStorage();

Uint8List _encode(Map<String, dynamic> value) =>
    Uint8List.fromList(gzip.encode(utf8.encode(jsonEncode(value))));
Map<String, dynamic> _decode(Uint8List bytes) =>
    jsonDecode(utf8.decode(gzip.decode(bytes))) as Map<String, dynamic>;

class FileHistoryStorage implements HistoryStorage {
  FileHistoryStorage({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;
  final Future<Directory> Function() _directory;
  Future<void> _serial = Future.value();

  Future<T> _run<T>(Future<T> Function() action) {
    final result = _serial.then((_) => action());
    _serial = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<Directory> _host(String host) async {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(host)) {
      throw const FormatException('Invalid cache key');
    }
    return Directory('${(await _directory()).path}/chat-history/$host');
  }

  Future<File> _file(String host, String session) async {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(session)) {
      throw const FormatException('Invalid cache key');
    }
    return File('${(await _host(host)).path}/$session.json.gz');
  }

  @override
  Future<Map<String, dynamic>?> read(String host, String session) =>
      _run(() async {
        final file = await _file(host, session);
        for (final candidate in [file, File('${file.path}.bak')]) {
          try {
            if (!await candidate.exists()) continue;
            final value = await compute(_decode, await candidate.readAsBytes());
            await candidate.setLastModified(DateTime.now());
            return value;
          } catch (_) {
            /* A write interrupted by termination can leave the backup. */
          }
        }
        return null;
      });

  @override
  Future<void> write(String host, String session, Map<String, dynamic> value) =>
      _run(() async {
        final bytes = await compute(_encode, value);
        if (bytes.length > 64 * 1024 * 1024) return;
        final file = await _file(host, session);
        await file.parent.create(recursive: true);
        final temporary = File('${file.path}.tmp');
        final backup = File('${file.path}.bak');
        await temporary.writeAsBytes(bytes, flush: true);
        if (await file.exists()) {
          if (await backup.exists()) await backup.delete();
          await file.rename(backup.path);
        }
        await temporary.rename(file.path);
        if (await backup.exists()) await backup.delete();
        final files = await file.parent
            .list()
            .where((f) => f is File && f.path.endsWith('.json.gz'))
            .cast<File>()
            .toList();
        final stats = [for (final f in files) (file: f, stat: await f.stat())];
        stats.sort((a, b) => b.stat.modified.compareTo(a.stat.modified));
        var total = 0;
        for (var i = 0; i < stats.length; i++) {
          total += stats[i].stat.size;
          if (i >= 32 || total > 128 * 1024 * 1024) {
            await stats[i].file.delete();
          }
        }
      });

  @override
  Future<void> remove(String host, String session) => _run(() async {
    final file = await _file(host, session);
    for (final suffix in ['', '.bak', '.tmp']) {
      final target = File('${file.path}$suffix');
      if (await target.exists()) await target.delete();
    }
  });

  @override
  Future<void> clear(String host) => _run(() async {
    final directory = await _host(host);
    if (await directory.exists()) await directory.delete(recursive: true);
  });
}
