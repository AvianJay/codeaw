// Optional PC-local real transcript fixture. Never includes private history in Git.
import 'dart:convert';
import 'dart:io';
import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/history_cache.dart';
import 'package:codeaw/data/history_storage_io.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/session_controller.dart';
import 'package:codeaw/data/timeline.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture = Platform.environment['CODEAW_REAL_HISTORY_FIXTURE'];
  test(
    'real long transcript persists and restores offline without changing its content',
    () async {
      final rows = jsonDecode(await File(fixture!).readAsString()) as List;
      final timeline = Timeline();
      for (final row in rows.cast<Map>()) {
        timeline.apply(
          row['kind'] == 'update' ? 'session/update' : '_codeaw/event',
          {
            if (row['kind'] == 'update')
              'update': Map<String, dynamic>.from(row['update'] as Map),
            if (row['kind'] == 'event')
              'event': Map<String, dynamic>.from(row['event'] as Map),
            '_meta': {
              'codeaw': {'seq': row['seq'], 't': row['t']},
            },
          },
        );
      }
      timeline.finishReplay();
      final root = await Directory.systemTemp.createTemp('codeaw-real-cache-');
      addTearDown(() => root.delete(recursive: true));
      final host = HostConfig(
        name: 'Real fixture',
        urls: ['ws://localhost/acp'],
        token: 'fixture-only',
        deviceId: 'fixture-only',
        deviceName: 'Test',
      );
      HistoryCache cache() => HistoryCache(
        host,
        storage: FileHistoryStorage(directory: () async => root),
      );
      final before = timeline.toSnapshot();
      final cursor = rows
          .cast<Map>()
          .map((r) => (r['seq'] as num).toInt())
          .reduce((a, b) => a > b ? a : b);
      final watch = Stopwatch()..start();
      await cache().write('codex:real-fixture', {
        'epoch': 'real-fixture',
        'lastSeq': cursor,
        'timeline': before,
      });
      final savedMs = watch.elapsedMilliseconds;
      watch.reset();
      final client = BridgeClient(host);
      final restored = SessionController(
        client,
        'codex:real-fixture',
        cache: cache(),
      );
      await restored.attach(); // Offline, no agent or network involved.
      expect(restored.timeline.toSnapshot(), before);
      expect(restored.lastSeq, cursor);
      expect(
        restored.timeline.items.whereType<ToolItem>().any(
          (t) => t.detailsDeferred,
        ),
        isTrue,
      );
      debugPrint(
        'Real history cache: ${timeline.items.length} items, write ${savedMs}ms, offline restore ${watch.elapsedMilliseconds}ms',
      );
      restored.dispose();
      client.dispose();
      timeline.dispose();
    },
    skip: fixture == null,
  );
}
