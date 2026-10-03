import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/session_controller.dart';
import 'package:codeaw/data/timeline.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a desktop history rebuild finishes replay and advances the reconnect cursor', () {
    final client = BridgeClient(HostConfig(name: 'fixture', urls: ['ws://localhost/acp'], token: 'fixture', deviceId: 'fixture', deviceName: 'fixture'));
    final controller = SessionController(client, 'codex:fixture');
    addTearDown(() { controller.dispose(); client.dispose(); });
    controller.lastSeq = 100;
    controller.epoch = 'old';
    void replay(String mode, {int? lastSeq}) => controller.onMessage(SessionMessage('_codeaw/replay', {'sessionId': controller.sessionId, 'mode': mode, 'epoch': 'new', 'lastSeq': lastSeq}));
    void chunk(int seq, String text) => controller.onMessage(SessionMessage('session/update', {
      'sessionId': controller.sessionId,
      'update': {'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': text}, '_meta': {'codeaw': {'mid': 'reply'}}},
      '_meta': {'codeaw': {'seq': seq}},
    }));
    replay('full'); chunk(1, 'rebuilt'); replay('complete', lastSeq: 1);
    chunk(2, ' plus live'); chunk(2, ' duplicate');
    controller.timeline.flush();
    expect(controller.epoch, 'new');
    expect(controller.lastSeq, 2);
    expect(controller.timeline.items.whereType<MessageItem>().single.text, 'rebuilt plus live');
  });

  test('desktop connection state follows bridge events independently of the phone socket', () {
    final client = BridgeClient(HostConfig(name: 'fixture', urls: ['ws://localhost/acp'], token: 'fixture', deviceId: 'fixture', deviceName: 'fixture'));
    final controller = SessionController(client, 'codex:fixture');
    addTearDown(() { controller.dispose(); client.dispose(); });
    void state(int seq, bool connected) => controller.onMessage(SessionMessage('_codeaw/event', {
      'sessionId': controller.sessionId,
      'event': {'type': 'state', 'state': connected ? 'running' : 'idle', 'queued': 0, 'connection': 'desktop', 'desktopConnected': connected},
      '_meta': {'codeaw': {'seq': seq}},
    }));
    state(1, true);
    expect(controller.desktopSync, isTrue);
    expect(controller.desktopConnected, isTrue);
    state(2, false);
    expect(controller.desktopSync, isTrue);
    expect(controller.desktopConnected, isFalse);
  });
}
