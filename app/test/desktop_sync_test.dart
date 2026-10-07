import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/history_cache.dart';
import 'package:codeaw/data/session_controller.dart';
import 'package:codeaw/data/timeline.dart';
import 'package:flutter_test/flutter_test.dart';

class DesktopClient extends BridgeClient {
  DesktopClient() : super(HostConfig(name: 'fixture', urls: ['ws://localhost/acp'], token: 'fixture', deviceId: 'fixture', deviceName: 'fixture')) {
    status = ConnStatus.online;
  }
  final calls = <String>[];
  late Future<dynamic> Function(String, Map<String, dynamic>?) handle;
  @override
  Future<dynamic> request(String method, [Map<String, dynamic>? params]) {
    calls.add(method);
    return handle(method, params);
  }
}

class EmptyHistory implements HistoryStorage {
  @override
  Future<Map<String, dynamic>?> read(String host, String session) async => null;
  @override
  Future<void> write(String host, String session, Map<String, dynamic> value) async {}
  @override
  Future<void> remove(String host, String session) async {}
  @override
  Future<void> clear(String host) async {}
}

void main() {
  test('a cold desktop load preserves history and drafts, then recovers and sends once without another load', () async {
    final client = DesktopClient();
    final controller = SessionController(client, 'codex:cold-desktop', cache: HistoryCache(client.host, storage: EmptyHistory()));
    addTearDown(() { controller.dispose(); client.dispose(); });
    void message(String method, Map<String, dynamic> params) => controller.onMessage(SessionMessage(method, {'sessionId': controller.sessionId, ...params}));
    void chunk(int seq) => message('session/update', {
      'update': {'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': 'saved history'}, '_meta': {'codeaw': {'mid': 'old-reply'}}},
      '_meta': {'codeaw': {'seq': seq}},
    });
    client.handle = (method, params) async {
      expect(method, 'session/load');
      message('_codeaw/replay', {'mode': 'full', 'epoch': 'saved'});
      chunk(1);
      return {'_meta': {'codeaw': {'epoch': 'saved', 'lastSeq': 1, 'state': 'idle', 'connection': 'desktop', 'desktopConnected': false}}};
    };
    await controller.attach();
    controller.draft = 'retained draft';
    expect(controller.attached, isTrue);
    expect(controller.error, isNull);
    expect(controller.waitingForDesktop, isTrue);
    expect(await controller.send([{'type': 'text', 'text': controller.draft}]), isFalse);
    expect(client.calls, ['session/load']);
    expect(controller.draft, 'retained draft');
    expect(controller.timeline.items.whereType<MessageItem>().single.text, 'saved history');
    // A recovered owner's authoritative snapshot replaces the saved replay.
    message('_codeaw/replay', {'mode': 'full', 'epoch': 'desktop'});
    chunk(1);
    message('_codeaw/replay', {'mode': 'complete', 'epoch': 'desktop', 'lastSeq': 1});
    message('_codeaw/event', {
      'event': {'type': 'state', 'state': 'idle', 'queued': 0, 'connection': 'desktop', 'desktopConnected': true},
      '_meta': {'codeaw': {'seq': 2}},
    });
    expect(controller.waitingForDesktop, isFalse);
    expect(controller.timeline.items.whereType<MessageItem>().single.text, 'saved history');
    client.handle = (method, params) async {
      expect(method, 'session/prompt');
      return {'stopReason': 'end_turn'};
    };
    expect(await controller.send([{'type': 'text', 'text': 'sent once'}]), isTrue);
    expect(client.calls, ['session/load', 'session/prompt']);
  });

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
