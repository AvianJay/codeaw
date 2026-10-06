import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'host.dart';
import 'history_storage.dart';
import 'history_storage_web.dart'
    if (dart.library.io) 'history_storage_io.dart'
    as platform;

export 'history_storage.dart';

class HistoryCache {
  HistoryCache(HostConfig host, {HistoryStorage? storage})
    : hostKey = digest('${host.deviceId}:${host.token}'),
      storage = storage ?? _defaultStorage;

  // URLs/names can change; credentials identify a pairing without storing its token.
  final String hostKey;
  final HistoryStorage storage;
  static final _defaultStorage = platform.createHistoryStorage();
  static String digest(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  Future<Map<String, dynamic>?> read(String sessionId) async {
    try {
      final value = await storage.read(hostKey, digest(sessionId));
      return value?['version'] == 1 && value?['sessionId'] == sessionId
          ? value
          : null;
    } catch (_) {
      return null;
    } // Corruption/storage limits never block chat.
  }

  Future<void> write(String sessionId, Map<String, dynamic> value) async {
    try {
      // Freeze mutable reducer maps before a queued write or isolate handoff.
      final snapshot =
          _copy({'version': 1, 'sessionId': sessionId, ...value})
              as Map<String, dynamic>;
      await storage.write(hostKey, digest(sessionId), snapshot);
    } catch (_) {
      /* Keep the last good snapshot when storage is unavailable. */
    }
  }

  static Object? _copy(Object? value) => switch (value) {
    Map v => <String, dynamic>{
      for (final e in v.entries) e.key as String: _copy(e.value),
    },
    List v => v.map(_copy).toList(),
    _ => value,
  };

  Future<void> remove(String sessionId) async {
    try {
      await storage.remove(hostKey, digest(sessionId));
    } catch (_) {}
  }

  Future<void> clear() async {
    try {
      await storage.clear(hostKey);
    } catch (_) {}
  }
}
