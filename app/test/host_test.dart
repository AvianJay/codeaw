import 'package:codeaw/data/host.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
