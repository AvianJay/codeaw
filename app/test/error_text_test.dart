import 'package:codeaw/acp/jsonrpc.dart';
import 'package:codeaw/ui/common/error_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const desktop = 'Claude Desktop 正在處理這個對話，等那一輪結束再傳。';
  const send = '另一個 App 正在這個對話裡執行，等它結束再傳。';
  const open = '另一個 App 正在這個對話裡執行，等它結束再開啟。';

  test('says in Chinese that a chat is in use elsewhere', () {
    expect(errorText('Claude Desktop is working on this chat right now. Send this after its turn there ends, or stop that turn first.'), desktop);
    expect(errorText('Another app is in the middle of a turn in this chat. Send this after that turn ends.'), send);
    expect(errorText('Another app is in the middle of a turn in this chat. Open it here once that turn ends.'), open);
    expect(errorText('Another app is in the middle of a turn in this chat. Reload it once that turn ends.'), open);
  });

  test('recognizes the sentence behind the JSON-RPC error kind', () {
    // What the bridge's `RequestError.invalidRequest(undefined, "…")` puts on the wire.
    final error = RpcError(-32600, 'Invalid request: Claude Desktop is working on this chat right now. Send this after its turn there ends, or stop that turn first.');
    expect(errorText(error.detail), desktop);
    expect(errorText('Invalid request: Another app is in the middle of a turn in this chat. Send this after that turn ends.'), send);
    expect(errorText('Invalid request: Another app is in the middle of a turn in this chat. Reload it once that turn ends.'), open);
  });

  test('leaves every other message as it arrived', () {
    for (final message in [
      'Invalid request: Chat is busy',
      'Another app is in the middle of a turn in this chat.',
      'The agent said: Claude Desktop is working on this chat right now.',
      '連線中斷，請稍後再試',
      '',
    ]) {
      expect(errorText(message), message);
    }
  });
}
