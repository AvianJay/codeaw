/// The text shown for an error that came from the computer.
///
/// The bridge writes its errors in English. The ones about a chat that another
/// app is using are common enough to say in the app's language; every other
/// message is shown as it arrived.
String errorText(String message) {
  // JSON-RPC puts the kind of error in front of the bridge's own sentence.
  const kind = 'Invalid request: ';
  final text = message.startsWith(kind) ? message.substring(kind.length) : message;
  if (text.startsWith('Claude Desktop is working on this chat right now.')) {
    return 'Claude Desktop 正在處理這個對話，等那一輪結束再傳。';
  }
  const otherApp = 'Another app is in the middle of a turn in this chat. ';
  if (text.startsWith('${otherApp}Send this')) {
    return '另一個 App 正在這個對話裡執行，等它結束再傳。';
  }
  if (text.startsWith('${otherApp}Open it') || text.startsWith('${otherApp}Reload it')) {
    return '另一個 App 正在這個對話裡執行，等它結束再開啟。';
  }
  return message;
}
