import 'dart:convert';
import 'dart:io';
import 'package:codeaw/data/bridge_frame.dart';
import 'package:codeaw/data/bridge_frame_web.dart' as web;
import 'package:codeaw/data/bridge_socket.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final text = jsonEncode({
    'jsonrpc': '2.0',
    'method': 'session/update',
    'params': {'text': '中文歷史訊息🙂' * 200},
  });
  test(
    'native and web gzip decoders preserve UTF-8 and legacy JSON frames',
    () {
      final bytes = gzip.encode(utf8.encode(text));
      expect(decodeBridgeFrame(text), text);
      expect(decodeBridgeFrame(utf8.encode(text)), text);
      expect(decodeBridgeFrame(bytes), text);
      expect(utf8.decode(web.inflate(bytes)), text);
      expect(() => decodeBridgeFrame([0x1f, 0x8b, 0]), throwsA(anything));
    },
  );
  test(
    'native socket opts into gzip while preserving query parameters and auth',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        expect(request.uri.queryParameters['existing'], 'keep');
        expect(request.uri.queryParameters['codeawCompression'], 'gzip');
        expect(request.headers.value('Authorization'), 'Bearer native-test');
        final ws = await WebSocketTransformer.upgrade(request);
        ws.add(gzip.encode(utf8.encode(text)));
        await ws.done;
      });
      final socket = connectBridgeSocket(
        'ws://127.0.0.1:${server.port}/acp?existing=keep',
        'native-test',
      );
      await socket.ready;
      expect(decodeBridgeFrame(await socket.stream.first), text);
      await socket.sink.close();
      await server.close(force: true);
    },
  );
}
