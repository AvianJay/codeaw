import 'package:web_socket_channel/web_socket_channel.dart';

// Browser WebSockets cannot set Authorization headers. The bridge also accepts
// the device token in the query string; keep this URL out of UI and error messages.
WebSocketChannel connectBridgeSocket(String url, String token) {
  final uri = Uri.parse(url);
  return WebSocketChannel.connect(uri.replace(queryParameters: {...uri.queryParameters, 'token': token, 'codeawCompression': 'gzip'}));
}
