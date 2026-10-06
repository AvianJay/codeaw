import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/history_cache.dart';
import 'package:codeaw/data/history_storage_io.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/session_controller.dart';
import 'package:codeaw/data/sessions_model.dart';
import 'package:codeaw/data/timeline.dart';
import 'package:flutter_test/flutter_test.dart';

HostConfig host([String id = 'A']) => HostConfig(
  name: 'PC',
  urls: ['ws://pc/acp'],
  token: 'token-$id',
  deviceId: id,
  deviceName: 'phone',
);

class MemoryHistory implements HistoryStorage {
  final values = <String, Map<String, dynamic>>{};
  @override
  Future<Map<String, dynamic>?> read(String host, String session) async =>
      values['$host/$session'];
  @override
  Future<void> write(
    String host,
    String session,
    Map<String, dynamic> value,
  ) async {
    values['$host/$session'] = value;
  }

  @override
  Future<void> remove(String host, String session) async {
    values.remove('$host/$session');
  }

  @override
  Future<void> clear(String host) async {
    values.removeWhere((key, _) => key.startsWith('$host/'));
  }
}

class Client extends BridgeClient {
  Client() : super(host());
  Future<dynamic> Function(String, Map<String, dynamic>?)? handle;
  void offline() {
    status = ConnStatus.offline;
    notifyListeners();
  }

  @override
  Future<dynamic> request(String method, [Map<String, dynamic>? params]) =>
      handle!(method, params);
}

void replay(SessionController c, String mode, String epoch, [int seq = 0]) =>
    c.onMessage(
      SessionMessage('_codeaw/replay', {
        'sessionId': c.sessionId,
        'mode': mode,
        'epoch': epoch,
        'lastSeq': seq,
      }),
    );
void update(SessionController c, int seq, Map<String, dynamic> u) =>
    c.onMessage(
      SessionMessage('session/update', {
        'sessionId': c.sessionId,
        'update': u,
        '_meta': {
          'codeaw': {'seq': seq, 't': seq * 1000},
        },
      }),
    );
Map<String, dynamic> text(
  String text, {
  String type = 'agent_message_chunk',
  String mid = 'reply',
}) => {
  'sessionUpdate': type,
  'content': {'type': 'text', 'text': text},
  '_meta': {
    'codeaw': {'mid': mid},
  },
};
void initial(SessionController c) {
  replay(c, 'full', 'one');
  update(c, 5, text('saved history'));
  update(c, 1, {'sessionUpdate': 'session_info_update', 'title': '我的聊天'});
  update(c, 4, {
    'sessionUpdate': 'tool_call',
    'toolCallId': 'tool',
    'title': 'Get-Content',
    'status': 'completed',
    '_meta': {
      'codeaw': {
        'deferredTool': {'seq': 4, 'bytes': 50000},
      },
    },
  });
  replay(c, 'complete', 'one', 5);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'restart restores history and cursor before network, also offline and isolated per host',
    () async {
      final storage = MemoryHistory(), client = Client();
      final cache = HistoryCache(client.host, storage: storage);
      final first = SessionController(
        client,
        'codex:test',
        cache: cache,
        cwd: 'C:/project',
      );
      initial(first);
      await first.persist();
      first.dispose();
      final restored = SessionController(client, 'codex:test', cache: cache);
      await restored.attach();
      expect(restored.timeline.title, '我的聊天');
      expect(
        restored.timeline.items.whereType<MessageItem>().single.text,
        'saved history',
      );
      expect(
        restored.timeline.items.whereType<ToolItem>().single.detailsDeferred,
        isTrue,
      );
      expect(restored.epoch, 'one');
      expect(restored.lastSeq, 5);
      expect(restored.cwd, 'C:/project');
      expect(
        await HistoryCache(host('B'), storage: storage).read('codex:test'),
        isNull,
      );
      client.status = ConnStatus.online;
      client.handle = (method, params) async {
        expect(restored.timeline.title, '我的聊天');
        expect(params!['_meta']['codeaw'], containsPair('afterSeq', 5));
        expect(params['_meta']['codeaw'], containsPair('epoch', 'one'));
        replay(restored, 'delta', 'one', 6);
        update(restored, 6, text(' plus new'));
        return {
          '_meta': {
            'codeaw': {'epoch': 'one', 'lastSeq': 6, 'state': 'idle'},
          },
        };
      };
      await restored.attach();
      expect(
        restored.timeline.items.whereType<MessageItem>().single.text,
        'saved history plus new',
      );
      await restored.persist();
      restored.dispose();
      client.dispose();
    },
  );
  test(
    'atomic full replay and interrupted rebuild preserve the last good durable history',
    () async {
      final storage = MemoryHistory(), client = Client();
      final cache = HistoryCache(client.host, storage: storage);
      final c = SessionController(client, 'codex:test', cache: cache);
      initial(c);
      await c.persist();
      c.timeline.addPendingPrompt('uncertain', [
        {'type': 'text', 'text': 'unsure send'},
      ]);
      replay(c, 'full', 'two');
      update(c, 1, text('partial replacement'));
      expect(
        c.timeline.items.whereType<MessageItem>().first.text,
        'saved history',
      );
      expect(c.epoch, 'one');
      expect(c.lastSeq, 5);
      await c.persist();
      expect((await cache.read(c.sessionId))!['epoch'], 'one');
      client.offline();
      replay(c, 'full', 'three');
      update(c, 10, text('complete replacement'));
      update(c, 2, {
        'sessionUpdate': 'session_info_update',
        'title': 'updated title',
      });
      replay(c, 'complete', 'three', 10);
      expect(c.timeline.title, 'updated title');
      expect(c.timeline.items.whereType<MessageItem>().map((m) => m.text), [
        'complete replacement',
        'unsure send',
      ]);
      update(c, 11, text(' plus live'));
      update(c, 11, text(' duplicate'));
      expect(
        c.timeline.items.whereType<MessageItem>().first.text,
        'complete replacement plus live',
      );
      expect(c.lastSeq, 11);
      expect(c.epoch, 'three');
      await c.persist();
      c.dispose();
      client.dispose();
    },
  );
  test(
    'snapshot retains images, receipts, tool children, permissions and turn footers',
    () {
      final t = Timeline();
      void apply(String method, Map<String, dynamic> body, int seq) =>
          t.apply(method, {
            ...body,
            '_meta': {
              'codeaw': {'seq': seq, 't': 1000 * seq},
            },
          });
      apply('session/update', {
        'update': {
          ...text('prompt', type: 'user_message_chunk', mid: 'u-p'),
          '_meta': {
            'codeaw': {'mid': 'u-p', 'promptId': 'p', 'receipt': 'read'},
          },
        },
      }, 1);
      apply('_codeaw/event', {
        'event': {
          'type': 'state',
          'state': 'running',
          'turnStartedAt': 2000,
          'turnPromptId': 'p',
        },
      }, 2);
      apply('session/update', {'update': text('hello 世界')}, 3);
      apply('session/update', {
        'update': {
          'sessionUpdate': 'agent_message_chunk',
          'content': {
            'type': 'image',
            'uri': 'codeaw-blob:${'a' * 64}',
            'data': '',
            'mimeType': 'image/png',
          },
          '_meta': {
            'codeaw': {'mid': 'reply'},
          },
        },
      }, 4);
      apply('session/update', {
        'update': {
          'sessionUpdate': 'tool_call',
          'toolCallId': 'parent',
          'name': 'spawn_agent',
          'status': 'completed',
          'rawOutput': {'agent_id': 'child'},
        },
      }, 5);
      apply('session/update', {
        'update': {
          'sessionUpdate': 'tool_call',
          'toolCallId': 'child-tool',
          'status': 'in_progress',
          '_meta': {
            'parentToolCallId': 'parent',
            'terminal_output': {'data': 'output', 'terminal_id': 'term'},
          },
        },
      }, 6);
      apply('_codeaw/event', {
        'event': {
          'type': 'permission_request',
          'requestId': 'permission',
          'toolCall': {'title': 'Read'},
          'options': [],
        },
      }, 7);
      apply('_codeaw/event', {
        'event': {
          'type': 'permission_resolved',
          'requestId': 'permission',
          'outcome': {'outcome': 'cancelled'},
        },
      }, 8);
      apply('_codeaw/event', {
        'event': {
          'type': 'state',
          'state': 'idle',
          'stopReason': 'end_turn',
          'completedTurn': {
            'promptId': 'p',
            'startedAt': 2000,
            'endedAt': 9000,
          },
        },
      }, 9);
      t.flush();
      final restored = Timeline.fromSnapshot(
        jsonDecode(jsonEncode(t.toSnapshot())) as Map<String, dynamic>,
      );
      restored.flush();
      expect(restored.debugSnapshot(), t.debugSnapshot());
      expect(restored.toSnapshot(), t.toSnapshot());
      expect(
        restored.items.whereType<TurnSummaryItem>().single.transcript,
        contains('hello 世界'),
      );
      expect(
        restored
            .childrenOf(restored.items.whereType<ToolItem>().first)
            .single
            .key,
        'tool:child-tool',
      );
      expect(restored.items.whereType<MessageItem>().first.receipt, 'read');
    },
  );
  test(
    'large tool hydration is exact and racing live updates cannot be overwritten',
    () async {
      final client = Client()..status = ConnStatus.online;
      final c = SessionController(
        client,
        'codex:test',
        cache: HistoryCache(client.host, storage: MemoryHistory()),
      );
      initial(c);
      final tool = c.timeline.items.whereType<ToolItem>().single;
      final output = '完整輸出\n' * 10000;
      var reply = Completer<Map>();
      client.handle = (method, params) => reply.future;
      final first = c.loadToolDetails(tool);
      update(c, 6, {
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'tool',
        'status': 'in_progress',
      });
      reply.complete({
        'epoch': 'one',
        'seq': 4,
        'update': {
          'toolCallId': 'tool',
          'status': 'completed',
          'rawOutput': output,
        },
      });
      await first;
      expect(tool.status, 'in_progress');
      expect(tool.detailsDeferred, isTrue);
      reply = Completer<Map>();
      final second = c.loadToolDetails(tool);
      reply.complete({
        'epoch': 'one',
        'seq': 6,
        'update': {
          'toolCallId': 'tool',
          'status': 'in_progress',
          'rawOutput': output,
          '_meta': {
            'terminal_output': {'data': output},
          },
        },
      });
      await second;
      expect(tool.rawOutput, output);
      expect(tool.terminalOutput, output);
      expect(tool.detailsDeferred, isFalse);
      // A folded reply can overtake a pending notification on another transport.
      tool.deferredSeq = 6;
      client.handle = (_, _) async => {
        'epoch': 'one',
        'seq': 8,
        'update': {
          'toolCallId': 'tool',
          'status': 'completed',
          '_meta': {
            'terminal_output': {'data': '$output ahead'},
          },
        },
      };
      await c.loadToolDetails(tool);
      expect(tool.terminalOutput, '$output ahead');
      update(c, 7, {
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'tool',
        '_meta': {
          'terminal_output_delta': {'data': ' ahead'},
        },
      });
      update(c, 8, {
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'tool',
        'status': 'completed',
      });
      expect(tool.terminalOutput, '$output ahead');
      update(c, 9, {
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'tool',
        '_meta': {
          'terminal_output_delta': {'data': ' newer'},
        },
      });
      expect(tool.terminalOutput, '$output ahead newer');
      expect(c.lastSeq, 9);
      expect(
        Timeline.fromSnapshot(
          c.timeline.toSnapshot(),
        ).items.whereType<ToolItem>().single.hydratedThroughSeq,
        8,
      );
      await c.persist();
      c.dispose();
      client.dispose();
    },
  );
  test('session list survives a cold offline launch', () async {
    final client = Client(),
        cache = HistoryCache(host(), storage: MemoryHistory());
    final first = SessionsModel(client, cache: cache);
    client.status = ConnStatus.online;
    client.handle = (_, _) async => {
      'sessions': [
        {'sessionId': 'codex:test', 'cwd': 'C:/project', 'title': '我的聊天'},
      ],
    };
    await first.refresh();
    await first.persist();
    first.dispose();
    client.offline();
    final second = SessionsModel(client, cache: cache);
    await second.restore();
    expect(second.sessions.single.displayTitle, '我的聊天');
    second.dispose();
    client.dispose();
  });
  test(
    'native storage survives another instance, freezes queued writes and recovers a backup',
    () async {
      final root = await Directory.systemTemp.createTemp('codeaw-history-');
      addTearDown(() => root.delete(recursive: true));
      final cache = HistoryCache(
        host(),
        storage: FileHistoryStorage(directory: () async => root),
      );
      final value = {
        'timeline': {'text': 'original'},
      };
      final pending = cache.write('codex:test', value);
      (value['timeline'] as Map)['text'] = 'changed after save';
      await pending;
      final other = HistoryCache(
        host(),
        storage: FileHistoryStorage(directory: () async => root),
      );
      expect((await other.read('codex:test'))!['timeline']['text'], 'original');
      final file = File(
        '${root.path}/chat-history/${cache.hostKey}/${HistoryCache.digest('codex:test')}.json.gz',
      );
      await file.copy('${file.path}.bak');
      await file.writeAsString('corrupt');
      expect((await other.read('codex:test'))!['timeline']['text'], 'original');
      await other.clear();
      expect(await other.read('codex:test'), isNull);
    },
  );
}
