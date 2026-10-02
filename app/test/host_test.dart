import 'package:codeaw/data/host.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('browser launch pairs on its serving origin and supports hash routes', () {
    final link = PairingLink.fromBrowserUri(Uri.parse('http://127.0.0.1:9876/?pair&c=ABCD1234&n=Office%20PC&u=ws://other/acp'))!;
    expect(link.urls, ['ws://127.0.0.1:9876/acp']);
    expect(link.code, 'ABCD1234');
    expect(link.hostName, 'Office PC');
    final hash = PairingLink.fromBrowserUri(Uri.parse('http://[::1]:7860/#/pair?pair&c=ABCD1234'))!;
    expect(hash.urls, ['ws://[::1]:7860/acp']);
    expect(PairingLink.fromBrowserUri(Uri.parse('https://pc.example/?pair&c=ABCD1234'))!.urls, ['wss://pc.example/acp']);
    for (final url in ['http://localhost/?pair', 'http://localhost/?pair&c=', 'http://localhost/?c=ABCD1234', 'codeaw://pair?pair&c=ABCD1234']) {
      expect(PairingLink.fromBrowserUri(Uri.parse(url)), isNull);
    }
  });

  test('accepts browser and native bridge addresses', () {
    expect(bridgeWebSocketUrl('https://pc.tailnet.ts.net/'), 'wss://pc.tailnet.ts.net/acp');
    expect(bridgeWebSocketUrl('http://100.64.0.1:7860'), 'ws://100.64.0.1:7860/acp');
    expect(bridgeWebSocketUrl('ws://100.64.0.1:7860/acp'), 'ws://100.64.0.1:7860/acp');
    expect(bridgeWebSocketUrl('pc.tailnet.ts.net', secure: true), 'wss://pc.tailnet.ts.net/acp');
    expect(bridgeWebSocketUrl('http://[::1]:7860/'), 'ws://[::1]:7860/acp');
    expect(HostConfig.httpBase('wss://pc.tailnet.ts.net/acp?token=private').toString(), 'https://pc.tailnet.ts.net');
    expect(() => bridgeWebSocketUrl('ftp://host'), throwsA(isA<PairingException>()));
    expect(() => bridgeWebSocketUrl('http://['), throwsA(isA<PairingException>()));
    expect(() => bridgeWebSocketUrl('https://user:password@host'), throwsA(isA<PairingException>()));
  });
}
