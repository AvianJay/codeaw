/// End-to-end: the app's BridgeClient + SessionController against a real bridge running the
/// scriptable fake agent (bridge/scripts/dev-bridge.ts). Needs Node and `npm install` in ../bridge.
@Tags(['e2e'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/session_controller.dart';
import 'package:codeaw/data/timeline.dart';
import 'package:codeaw/data/terminal_controller.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> until(bool Function() cond, {Duration timeout = const Duration(seconds: 10)}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

String agentText(SessionController c) =>
    c.timeline.items.whereType<MessageItem>().where((m) => m.role == MessageRole.agent).map((m) => m.text).join('|');

void main() {
  late Process bridge;
  late Map<String, dynamic> info;
  final cleanups = <void Function()>[];

  setUpAll(() async {
    bridge = await Process.start('node', ['--import', 'tsx', 'scripts/dev-bridge.ts'], workingDirectory: '../bridge');
    bridge.stderr.drain<void>();
    final line = await bridge.stdout.transform(utf8.decoder).transform(const LineSplitter()).firstWhere((l) => l.startsWith('{')).timeout(const Duration(seconds: 30));
    info = jsonDecode(line) as Map<String, dynamic>;
  });

  tearDownAll(() async {
    for (final c in cleanups) {
      c();
    }
    await bridge.stdin.close();
    await bridge.exitCode.timeout(const Duration(seconds: 8), onTimeout: () {
      bridge.kill();
      return -1;
    });
  });

  BridgeClient connect() {
    final client = BridgeClient(HostConfig(name: 'test', urls: [info['url'] as String], token: info['token'] as String, deviceId: 'd', deviceName: 'flutter-test'))..start();
    cleanups.add(client.dispose);
    return client;
  }

  test('creates a session, streams, answers a permission, survives a dropped connection', () async {
    final client = connect();
    await client.connected.first.timeout(const Duration(seconds: 15));
    expect(client.agents.map((a) => a.id), ['fake']);
    final hub = SessionHub(client);
    cleanups.add(hub.dispose);

    final cwd = info['home'] as String;
    final resp = await client.request('session/new', {
      'cwd': cwd,
      'mcpServers': const [],
      '_meta': {
        'codeaw': {'agentId': 'fake'},
      },
    }) as Map<String, dynamic>;
    final id = resp['sessionId'] as String;
    final c = hub.adopt(id, cwd, resp);
    expect(c.configOptions.single.currentLabel, 'Ask');

    await c.send([
      {'type': 'text', 'text': 'echo hi there'},
    ]);
    await until(() => agentText(c).contains('hi there') && c.timeline.state == 'idle');
    expect(c.timeline.items.whereType<MessageItem>().first.text, 'echo hi there');

    unawaited(c.send([
      {'type': 'text', 'text': 'perm'},
    ]));
    await until(() => c.pending.isNotEmpty);
    final req = c.pending.values.single;
    expect(req.title, 'rm -rf build');
    c.answerPermission(req, 'allow');
    await until(() => agentText(c).contains('allowed') && c.timeline.state == 'idle');
    expect(c.timeline.items.whereType<PermissionItem>().single.by, 'dev'); // the bridge's name for this device token

    // Drop the socket mid-turn; the turn keeps running on the bridge and the controller
    // catches up with a delta replay after the automatic reconnect.
    unawaited(c.send([
      {'type': 'text', 'text': 'slow 25'},
    ]));
    await until(() => agentText(c).contains('3 '));
    final before = c.lastSeq;
    await client.debugDropConnection();
    await until(() => !client.isOnline, timeout: const Duration(seconds: 5));
    client.reconnectNow();
    await until(() => client.isOnline && c.attached, timeout: const Duration(seconds: 15));
    await until(() => c.timeline.state == 'idle' && agentText(c).contains('24 '));
    expect(c.lastSeq, greaterThan(before));
    final slow = c.timeline.items.whereType<MessageItem>().where((m) => m.role == MessageRole.agent && m.text.startsWith('0 1 2')).single;
    expect(slow.text, List.generate(25, (i) => '$i ').join());

    // A second device gets a compacted full replay that reduces to the same timeline.
    final other = connect();
    await other.connected.first.timeout(const Duration(seconds: 15));
    final hub2 = SessionHub(other);
    cleanups.add(hub2.dispose);
    final c2 = hub2.open(id, cwd: cwd);
    await until(() => c2.attached && !c2.loading);
    c2.timeline.flush();
    c.timeline.flush();
    expect(c2.timeline.debugSnapshot()['items'], c.timeline.debugSnapshot()['items']);
    expect(c2.lastSeq, c.lastSeq);
  });

  test('terminal streams, reattaches without duplicates, and restarts after shell exit', () async {
    final client = connect();
    await client.connected.first.timeout(const Duration(seconds: 15));
    final hub = TerminalHub(client);
    cleanups.add(hub.dispose);
    final c = hub.open(info['home'] as String);
    await c.attach();
    expect(c.error, isNull);
    expect(c.canInput, isTrue);
    final id = c.terminalId;
    await until(() => Platform.isWindows ? c.terminal.buffer.getText().contains('> ') : c.lastSeq > 0);
    await c.write(Platform.isWindows ? "Write-Output ('flutter-' + 'terminal')\r" : "printf 'flutter-%s\\n' terminal\r");
    await until(() => c.terminal.buffer.getText().contains('flutter-terminal'));
    final seq = c.lastSeq;
    await client.debugDropConnection();
    await until(() => !client.isOnline);
    expect(c.canInput, isFalse);
    client.reconnectNow();
    await until(() => c.canInput, timeout: const Duration(seconds: 15));
    expect(c.terminalId, id);
    expect(c.lastSeq, greaterThanOrEqualTo(seq));
    expect('flutter-terminal'.allMatches(c.terminal.buffer.getText()), hasLength(1));
    await c.write('node -e "console.log(\'busy-\' + \'started\');setInterval(()=>{},1000)"\r');
    await until(() => c.terminal.buffer.getText().contains('busy-started'));
    await c.write('\x03');
    await until(() => RegExp(r'[>$#%]\s*$').hasMatch(c.terminal.buffer.getText()));
    await c.write('exit 3\r');
    await until(() => c.exited);
    expect(c.exitCode, 3);
    expect(c.canInput, isFalse);
    await c.restart();
    expect(c.terminalId, isNot(id));
    expect(c.canInput, isTrue);
    c.detach();
  });
}
