import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codeaw/acp/jsonrpc.dart';
import 'package:codeaw/data/file_download.dart';
import 'package:codeaw/data/file_download_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // These transport tests deliberately use a real local HTTP server.
  HttpOverrides.global = null;
  late Directory directory;
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('codeaw-download-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, (call) async => directory.path);
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, null);
    await directory.delete(recursive: true);
  });

  test('download names are safe for drive-root ZIPs and local storage', () {
    expect(safeDownloadName('D:.zip'), 'D_.zip');
    expect(safeDownloadName('../蔥 音樂.wav'), '蔥 音樂.wav');
    expect(safeDownloadName('bad\r\n".txt '), 'bad___.txt');
    expect(safeDownloadName('..'), 'download');
  });

  test(
    'native download streams authenticated binary bytes with progress and original Unicode filename',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final chunk = List<int>.generate(64 * 1024, (i) => i % 251), count = 384;
      final expected = sha256.convert(
        List<int>.generate(chunk.length * count, (i) => i % chunk.length % 251),
      );
      final serving = server.first.then((request) async {
        expect(request.headers.value('authorization'), 'Bearer fixture');
        expect(request.uri.queryParameters['download'], '1');
        request.response.contentLength = chunk.length * count;
        request.response.headers.contentType = ContentType('audio', 'wav');
        for (var i = 0; i < count; i++) {
          request.response.add(chunk);
          await request.response.flush();
        }
        await request.response.close();
      });
      final progress = <int>[];
      final file = await fetchDownload(
        Uri.parse('http://127.0.0.1:${server.port}/api/fs/raw?download=1'),
        {'Authorization': 'Bearer fixture'},
        name: '蔥 音樂.wav',
        onProgress: (received, total) {
          expect(total, chunk.length * count);
          progress.add(received);
        },
      );
      await serving;
      expect(file.name, '蔥 音樂.wav');
      expect(file.mimeType, 'audio/wav');
      expect(file.size, chunk.length * count);
      expect(await sha256.bind(File(file.path).openRead()).first, expected);
      expect(progress.first, 0);
      expect(progress.last, file.size);
      expect(progress.length, greaterThan(2));
      for (var i = 1; i < progress.length; i++) {
        expect(progress[i], greaterThan(progress[i - 1]));
      }
      await file.dispose();
      expect(await File(file.path).exists(), false);
    },
  );

  test(
    'ZIP request carries selected paths, streams into a temporary file and reports server errors',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final handlers = server.take(2).forEach((request) async {
        expect(request.method, 'POST');
        expect(request.headers.contentType?.mimeType, 'application/json');
        expect(jsonDecode(await utf8.decoder.bind(request).join()), {
          'path': 'D:/Music',
          'paths': ['D:/Music/song.wav'],
        });
        if (request.uri.path == '/good') {
          request.response.contentLength = 4;
          request.response.headers.contentType = ContentType(
            'application',
            'zip',
          );
          request.response.add([80, 75, 3, 4]);
        } else {
          request.response.statusCode = 403;
          request.response.write(
            '{"error":"Path is outside the allowed workspaces"}',
          );
        }
        await request.response.close();
      });
      final body = jsonEncode({
        'path': 'D:/Music',
        'paths': ['D:/Music/song.wav'],
      });
      final file = await fetchDownload(
        Uri.parse('http://127.0.0.1:${server.port}/good'),
        {},
        name: 'Music.zip',
        body: body,
      );
      expect(await File(file.path).readAsBytes(), [80, 75, 3, 4]);
      await file.dispose();
      await expectLater(
        fetchDownload(
          Uri.parse('http://127.0.0.1:${server.port}/bad'),
          {},
          name: 'Music.zip',
          body: body,
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('outside'),
          ),
        ),
      );
      await handlers;
      expect(await directory.list().toList(), isEmpty);
    },
  );

  test('cancel closes the transfer and removes partial files', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final release = Completer<void>(), cancel = CancelToken();
    final serving = server.first.then((request) async {
      request.response.contentLength = 1024 * 1024;
      request.response.add(List<int>.filled(65536, 7));
      try {
        await request.response.flush();
        await release.future;
        await request.response.close();
      } catch (_) {}
    });
    await expectLater(
      fetchDownload(
        Uri.parse('http://127.0.0.1:${server.port}/file'),
        {},
        name: 'partial.wav',
        cancel: cancel,
        onProgress: (received, _) {
          if (received > 0) cancel.cancel();
        },
      ),
      throwsA(isA<DownloadCancelled>()),
    );
    release.complete();
    await serving;
    expect(await directory.list().toList(), isEmpty);
  });

  test(
    'timeout stops a stalled transfer before cleaning up partial files',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final release = Completer<void>();
      final serving = server.first.then((request) async {
        request.response.contentLength = 1024 * 1024;
        request.response.add(List<int>.filled(65536, 7));
        try {
          await request.response.flush();
          await release.future;
          await request.response.close();
        } catch (_) {}
      });
      await expectLater(
        fetchDownload(
          Uri.parse('http://127.0.0.1:${server.port}/file'),
          {},
          name: 'timeout.wav',
          timeout: const Duration(milliseconds: 200),
        ),
        throwsA(isA<TimeoutException>()),
      );
      release.complete();
      await serving;
      expect(await directory.list().toList(), isEmpty);
    },
  );

  test('truncated HTTP responses never produce a shareable file', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final serving = server.first.then((request) async {
      request.response.contentLength = 1024 * 1024;
      request.response.add(List<int>.filled(65536, 7));
      await request.response.flush();
      await server.close(force: true);
    });
    await expectLater(
      fetchDownload(
        Uri.parse('http://127.0.0.1:${server.port}/file'),
        {},
        name: 'truncated.wav',
      ),
      throwsA(isA<Exception>()),
    );
    await serving;
    expect(await directory.list().toList(), isEmpty);
  });
}
