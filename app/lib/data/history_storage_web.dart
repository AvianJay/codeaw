import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'history_storage.dart';

HistoryStorage createHistoryStorage() => _BrowserHistoryStorage();

/// IndexedDB supports large, durable snapshots without localStorage's small quota.
class _BrowserHistoryStorage implements HistoryStorage {
  Future<web.IDBDatabase>? _opening;
  Future<void> _serial = Future.value();
  Future<T> _run<T>(Future<T> Function() action) {
    final result = _serial.then((_) => action());
    _serial = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<web.IDBDatabase> _open() => _opening ??= () async {
    final request = web.window.indexedDB.open('codeaw-chat-history', 1);
    request.onupgradeneeded = ((web.Event _) {
      (request.result as web.IDBDatabase).createObjectStore('sessions');
    }).toJS;
    final database = await _request(request) as web.IDBDatabase;
    database.onversionchange = ((web.Event _) {
      database.close();
      _opening = null;
    }).toJS;
    return database;
  }();

  Future<JSAny?> _request(web.IDBRequest request) {
    final done = Completer<JSAny?>();
    request.onsuccess = ((web.Event _) {
      done.complete(request.result);
    }).toJS;
    request.onerror = ((web.Event _) {
      done.completeError(StateError('History storage request failed'));
    }).toJS;
    return done.future;
  }

  Future<void> _commit(web.IDBTransaction transaction) {
    final done = Completer<void>();
    transaction.oncomplete = ((web.Event _) {
      if (!done.isCompleted) done.complete();
    }).toJS;
    void fail(web.Event _) {
      if (!done.isCompleted) {
        done.completeError(StateError('History storage transaction failed'));
      }
    }

    transaction.onabort = fail.toJS;
    transaction.onerror = fail.toJS;
    return done.future;
  }

  web.IDBKeyRange _range(String host) =>
      web.IDBKeyRange.bound('$host/'.toJS, '$host/\uffff'.toJS);

  @override
  Future<Map<String, dynamic>?> read(String host, String session) =>
      _run(() async {
        final db = await _open();
        final tx = db.transaction('sessions'.toJS, 'readonly');
        final raw = (await _request(
          tx.objectStore('sessions').get('$host/$session'.toJS),
        ))?.dartify();
        if (raw is! Map || raw['value'] is! String) return null;
        return jsonDecode(raw['value'] as String) as Map<String, dynamic>;
      });

  @override
  Future<void> write(String host, String session, Map<String, dynamic> value) =>
      _run(() async {
        final json = jsonEncode(value);
        if (json.length > 64 * 1024 * 1024) return;
        final db = await _open();
        final tx = db.transaction('sessions'.toJS, 'readwrite');
        final done = _commit(tx);
        tx
            .objectStore('sessions')
            .put(
              {
                'value': json,
                'time': DateTime.now().millisecondsSinceEpoch,
              }.jsify(),
              '$host/$session'.toJS,
            );
        await done;
        final read = db
            .transaction('sessions'.toJS, 'readonly')
            .objectStore('sessions');
        final keys =
            (await _request(read.getAllKeys(_range(host))))!.dartify() as List;
        // Read individually so older browsers need no getAllRecords support.
        final rows = <({String key, int time, int size})>[];
        for (final key in keys.cast<String>()) {
          final store = db
              .transaction('sessions'.toJS, 'readonly')
              .objectStore('sessions');
          final row = (await _request(store.get(key.toJS)))!.dartify() as Map;
          rows.add((
            key: key,
            time: (row['time'] as num).toInt(),
            size: (row['value'] as String).length * 2,
          ));
        }
        rows.sort((a, b) => b.time.compareTo(a.time));
        final prune = db.transaction('sessions'.toJS, 'readwrite');
        final pruned = _commit(prune);
        var total = 0;
        for (var i = 0; i < rows.length; i++) {
          total += rows[i].size;
          if (i >= 32 || total > 128 * 1024 * 1024) {
            prune.objectStore('sessions').delete(rows[i].key.toJS);
          }
        }
        await pruned;
      });

  @override
  Future<void> remove(String host, String session) => _run(() async {
    final tx = (await _open()).transaction('sessions'.toJS, 'readwrite');
    final done = _commit(tx);
    tx.objectStore('sessions').delete('$host/$session'.toJS);
    await done;
  });

  @override
  Future<void> clear(String host) => _run(() async {
    final db = await _open();
    final keys =
        (await _request(
              db
                  .transaction('sessions'.toJS, 'readonly')
                  .objectStore('sessions')
                  .getAllKeys(_range(host)),
            ))!.dartify()
            as List;
    final tx = db.transaction('sessions'.toJS, 'readwrite');
    final done = _commit(tx);
    for (final key in keys.cast<String>()) {
      tx.objectStore('sessions').delete(key.toJS);
    }
    await done;
  });
}
