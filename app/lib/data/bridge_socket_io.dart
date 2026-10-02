import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

WebSocketChannel connectBridgeSocket(String url, String token) => IOWebSocketChannel.connect(
  url,
  headers: {'Authorization': 'Bearer $token'},
  pingInterval: const Duration(seconds: 15),
  connectTimeout: const Duration(seconds: 8),
);
