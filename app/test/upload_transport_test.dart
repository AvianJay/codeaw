import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/upload_transport_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:file_selector/file_selector.dart';
import 'package:crypto/crypto.dart';

class _StreamingFile extends XFile {
  _StreamingFile(super.path);
  @override
  Future<Uint8List> readAsBytes() =>
      throw StateError('Must stream large files');
}

void main() {
  test(
    'picked files above 20 MiB stream with progress without whole-file reads',
    () async {
      final directory = await Directory.systemTemp.createTemp('codeaw-upload-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/large.bin');
      final handle = await file.open(mode: FileMode.write);
      await handle.truncate(24 * 1024 * 1024);
      await handle.close();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final expectedHash = await sha256.bind(file.openRead()).first;
      final handler = server.first.then((request) async {
        expect(request.contentLength, 24 * 1024 * 1024);
        expect(await sha256.bind(request).first, expectedHash);
        request.response.statusCode = 201;
        request.response.write(
          jsonEncode({
            'block': {
              'type': 'resource_link',
              'name': 'large.bin',
              'uri': 'file:///large.bin',
            },
          }),
        );
        await request.response.close();
      });
      final client = BridgeClient(
        HostConfig(
          name: 'test',
          urls: ['ws://127.0.0.1:${server.port}/acp'],
          token: 'fixture',
          deviceId: 'test',
          deviceName: 'test',
        ),
      );
      addTearDown(client.dispose);
      final progress = <int>[];
      expect(
        (await client.uploadPickedFile(
          'codex:one',
          _StreamingFile(file.path),
          onProgress: (sent, total) {
            expect(total, 24 * 1024 * 1024);
            progress.add(sent);
          },
        ))['name'],
        'large.bin',
      );
      expect(progress.first, 0);
      expect(progress.last, 24 * 1024 * 1024);
      for (var i = 1; i < progress.length; i++) {
        expect(progress[i], greaterThan(progress[i - 1]));
      }
      await handler;
      final oversized = File('${directory.path}/oversized.bin');
      final oversizedHandle = await oversized.open(mode: FileMode.write);
      await oversizedHandle.truncate(maxUploadBytes + 1);
      await oversizedHandle.close();
      await expectLater(
        client.uploadPickedFile('codex:one', _StreamingFile(oversized.path)),
        throwsA(isA<FormatException>()),
      );
    },
  );
  test(
    'native upload reports monotonic byte progress and waits for stored response',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final received = Completer<void>();
      final reply = Completer<void>();
      final bytes = Uint8List.fromList(
        List.generate(2 * 1024 * 1024 + 13, (i) => i % 251),
      );
      final handler = server.first.then((request) async {
        expect(request.headers.value('authorization'), 'Bearer fixture');
        expect(request.contentLength, bytes.length);
        expect(request.uri.queryParameters, {
          'sessionId': 'codex:one',
          'name': '音訊.wav',
        });
        final body = await request.fold(
          BytesBuilder(copy: false),
          (all, chunk) => all..add(chunk),
        );
        expect(body.takeBytes(), bytes);
        received.complete();
        await reply.future;
        request.response.statusCode = 201;
        request.response.write(
          jsonEncode({
            'block': {
              'type': 'resource_link',
              'name': '音訊.wav',
              'uri': 'file:///audio.wav',
            },
          }),
        );
        await request.response.close();
      });
      final client = BridgeClient(
        HostConfig(
          name: 'test',
          urls: ['ws://127.0.0.1:${server.port}/acp'],
          token: 'fixture',
          deviceId: 'test',
          deviceName: 'test',
        ),
      );
      addTearDown(client.dispose);
      final progress = <int>[];
      final transferred = Completer<void>();
      var confirmed = false;
      final upload = client
          .uploadFile(
            'codex:one',
            '音訊.wav',
            bytes,
            onProgress: (sent, total) {
              expect(total, bytes.length);
              progress.add(sent);
              if (sent == total && !transferred.isCompleted) {
                transferred.complete();
              }
            },
          )
          .then((value) {
            confirmed = true;
            return value;
          });
      await received.future.timeout(const Duration(seconds: 10));
      await transferred.future;
      expect(confirmed, isFalse);
      expect(progress.first, 0);
      expect(progress.last, bytes.length);
      expect(progress.length, greaterThan(3));
      for (var i = 1; i < progress.length; i++) {
        expect(progress[i], greaterThan(progress[i - 1]));
      }
      reply.complete();
      expect((await upload)['name'], '音訊.wav');
      await handler;
    },
  );

  test(
    'native upload timeout aborts the request instead of claiming success',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final request = server.first.then((request) async {
        await request.drain<void>();
      });
      await expectLater(
        uploadBytes(
          Uri.parse('http://127.0.0.1:${server.port}/upload'),
          {},
          Uint8List(16),
          timeout: const Duration(milliseconds: 100),
        ),
        throwsA(isA<TimeoutException>()),
      );
      await request;
    },
  );
}
