import 'dart:async';
import 'dart:convert';

import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/models.dart';
import 'package:codeaw/data/session_controller.dart';
import 'package:codeaw/acp/jsonrpc.dart';
import 'package:codeaw/ui/chat/composer.dart';
import 'package:codeaw/util/image_clipboard.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
);

class _Clipboard implements ImageClipboard {
  _Clipboard({this.usesPasteEvents = false});
  @override
  final bool usesPasteEvents;
  Future<ImagePaste> result = Future.value(const ImagePaste());
  Future<ImagePaste> Function()? onRead;
  int reads = 0;
  bool stopped = false;
  late bool Function() canPaste;
  late void Function(Future<ImagePaste>) onPaste;

  @override
  Future<ImagePaste> read() {
    reads++;
    return onRead?.call() ?? result;
  }

  @override
  VoidCallback listen({
    required bool Function() canPaste,
    required void Function(Future<ImagePaste>) onPaste,
  }) {
    this.canPaste = canPaste;
    this.onPaste = onPaste;
    return () => stopped = true;
  }

  bool emit(ImagePaste paste) {
    if (stopped || !canPaste()) return false;
    onPaste(Future.value(paste));
    return true;
  }
}

class _Client extends BridgeClient {
  _Client({bool images = true})
    : super(
        HostConfig(
          name: 'fixture',
          urls: ['ws://localhost/acp'],
          token: 'fixture',
          deviceId: 'fixture',
          deviceName: 'fixture',
        ),
      ) {
    status = ConnStatus.online;
    agents = [
      AgentInfo(id: 'codex', name: 'Codex', status: 'ready', image: images),
    ];
  }
  final prompts = <Map<String, dynamic>>[];
  final uploads = <({String sessionId, String name, Uint8List bytes})>[];
  bool failPrompt = false;
  Completer<dynamic>? pendingPrompt;
  Future<Map<String, dynamic>> Function(
    String name,
    Uint8List bytes,
    UploadProgressCallback? progress,
  )?
  onUpload;

  @override
  Future<Map<String, dynamic>> uploadPickedFile(
    String sessionId,
    XFile file, {
    UploadProgressCallback? onProgress,
  }) async {
    final data = <int>[];
    await for (final chunk in file.openRead()) {
      data.addAll(chunk);
    }
    return uploadFile(
      sessionId,
      file.name,
      Uint8List.fromList(data),
      onProgress: onProgress,
    );
  }

  @override
  Future<Map<String, dynamic>> uploadFile(
    String sessionId,
    String name,
    Uint8List bytes, {
    UploadProgressCallback? onProgress,
  }) async {
    uploads.add((sessionId: sessionId, name: name, bytes: bytes));
    if (onUpload != null) return onUpload!(name, bytes, onProgress);
    return {
      'type': 'resource_link',
      'name': name,
      'uri': 'file:///workspace/$name',
    };
  }

  @override
  Future<dynamic> request(String method, [Map<String, dynamic>? params]) async {
    if (method == 'session/prompt') {
      if (failPrompt) throw const FormatException('Connection lost');
      prompts.add(params!);
      if (pendingPrompt != null) return pendingPrompt!.future;
    }
    return {};
  }
}

Widget _app(
  SessionController controller,
  _Clipboard clipboard, {
  Future<List<XFile>> Function()? pickFiles,
}) => MaterialApp(
  home: Scaffold(
    body: Column(
      children: [
        const TextField(key: ValueKey('other-field')),
        const Spacer(),
        Composer(
          controller: controller,
          imageClipboard: clipboard,
          pickFiles: pickFiles,
        ),
      ],
    ),
  ),
);

Finder get _input => find.descendant(
  of: find.byType(Composer),
  matching: find.byType(TextField),
);

Future<({SessionController controller, _Client client})> _show(
  WidgetTester tester,
  _Clipboard clipboard, {
  bool images = true,
  Future<List<XFile>> Function()? pickFiles,
}) async {
  tester.view.physicalSize = const Size(834, 1112);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final client = _Client(images: images);
  final controller = SessionController(client, 'codex:one');
  addTearDown(() {
    controller.dispose();
    client.dispose();
  });
  await tester.pumpWidget(_app(controller, clipboard, pickFiles: pickFiles));
  await tester.pumpAndSettle();
  return (controller: controller, client: client);
}

Future<void> _pasteKey(
  WidgetTester tester, {
  bool meta = false,
  bool settle = true,
}) async {
  final modifier = meta
      ? LogicalKeyboardKey.metaLeft
      : LogicalKeyboardKey.controlLeft;
  await tester.sendKeyDownEvent(modifier);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
  await tester.sendKeyUpEvent(modifier);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

void main() {
  String clipboardText = '';
  setUp(() {
    clipboardText = '';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.getData') {
            return {'text': clipboardText};
          }
          if (call.method == 'Clipboard.hasStrings') {
            return {'value': clipboardText.isNotEmpty};
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    debugDefaultTargetPlatformOverride = null;
  });

  for (final mac in [false, true]) {
    testWidgets(
      '${mac ? 'Command' : 'Ctrl'}+V attaches a clipboard image and sends it with text',
      (tester) async {
        final clipboard = _Clipboard()
          ..result = Future.value(
            ImagePaste(images: [ClipboardImage.fromBytes(_png)]),
          );
        final h = await _show(tester, clipboard);
        expect(clipboard.reads, 0);
        await tester.enterText(_input, 'Describe this screenshot');
        await _pasteKey(tester, meta: mac);
        expect(find.byType(Image), findsOneWidget);
        expect(h.client.prompts, isEmpty);
        await tester.tap(find.byTooltip('送出'));
        await tester.pumpAndSettle();
        expect(h.client.prompts.single['prompt'], [
          {'type': 'text', 'text': 'Describe this screenshot'},
          {
            'type': 'image',
            'mimeType': 'image/png',
            'data': base64Encode(_png),
          },
        ]);
        expect(find.byType(Image), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        expect(clipboard.stopped, isTrue);
      },
      variant: TargetPlatformVariant({
        mac ? TargetPlatform.macOS : TargetPlatform.windows,
      }),
    );
  }

  testWidgets('ordinary paste replaces only selected text and supports undo', (
    tester,
  ) async {
    final clipboard = _Clipboard();
    await _show(tester, clipboard);
    await tester.enterText(_input, 'abcXXdef');
    await tester.pump(const Duration(seconds: 1));
    tester.widget<TextField>(_input).controller!.selection =
        const TextSelection(baseOffset: 3, extentOffset: 5);
    clipboardText = ' pasted ';
    await _pasteKey(tester);
    expect(tester.widget<TextField>(_input).controller!.text, 'abc pasted def');
    expect(find.byType(Image), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(_input).controller!.text, 'abcXXdef');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets(
    'image menu pastes without reading on focus and lets users remove the attachment',
    (tester) async {
      final clipboard = _Clipboard()
        ..result = Future.value(
          ImagePaste(images: [ClipboardImage.fromBytes(_png)]),
        );
      await _show(tester, clipboard);
      await tester.tap(_input);
      await tester.pumpAndSettle();
      expect(clipboard.reads, 0);
      await tester.tap(find.byTooltip('附加'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('貼上剪貼簿圖片'));
      await tester.pumpAndSettle();
      expect(clipboard.reads, 1);
      expect(find.byType(Image), findsOneWidget);
      await tester.tap(find.byTooltip('移除圖片'));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'paste events accept multiple images and text only in the active composer',
    (tester) async {
      final clipboard = _Clipboard(usesPasteEvents: true);
      final h = await _show(tester, clipboard);
      final paste = ImagePaste(
        images: [
          ClipboardImage.fromBytes(_png),
          ClipboardImage.fromBytes(_png),
        ],
        text: 'pasted description',
      );
      await tester.tap(find.byKey(const ValueKey('other-field')));
      await tester.pumpAndSettle();
      expect(clipboard.emit(paste), isFalse);
      await tester.enterText(_input, 'before after');
      tester.widget<TextField>(_input).controller!.selection =
          const TextSelection.collapsed(offset: 7);
      expect(clipboard.emit(paste), isTrue);
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNWidgets(2));
      expect(
        tester.widget<TextField>(_input).controller!.text,
        'before pasted descriptionafter',
      );
      await tester.tap(find.byTooltip('送出'));
      await tester.pumpAndSettle();
      expect((h.client.prompts.single['prompt'] as List).length, 3);
      expect(clipboard.reads, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'pending clipboard images disable send and never cross sessions',
    (tester) async {
      final pending = Completer<ImagePaste>();
      final clipboard = _Clipboard()..result = pending.future;
      final h = await _show(tester, clipboard);
      await tester.enterText(_input, 'draft one');
      await _pasteKey(tester, settle: false);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.arrow_upward_rounded),
            )
            .onPressed,
        isNull,
      );
      final next = SessionController(h.client, 'codex:two');
      addTearDown(next.dispose);
      await tester.pumpWidget(_app(next, clipboard));
      await tester.pumpAndSettle();
      pending.complete(ImagePaste(images: [ClipboardImage.fromBytes(_png)]));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(tester.widget<TextField>(_input).controller!.text, isEmpty);
      expect(h.controller.draft, 'draft one');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'agents without image support preserve text paste and ignore image events',
    (tester) async {
      final clipboard = _Clipboard(usesPasteEvents: true);
      await _show(tester, clipboard, images: false);
      await tester.enterText(_input, 'hello ');
      clipboardText = 'text';
      await _pasteKey(tester);
      expect(tester.widget<TextField>(_input).controller!.text, 'hello text');
      expect(
        clipboard.emit(ImagePaste(images: [ClipboardImage.fromBytes(_png)])),
        isFalse,
      );
      expect(clipboard.reads, 0);
      expect(find.byTooltip('附加'), findsOneWidget);
      await tester.tap(find.byTooltip('附加'));
      await tester.pumpAndSettle();
      expect(find.text('上傳檔案'), findsOneWidget);
      expect(find.text('從相簿選擇'), findsNothing);
      expect(find.text('貼上剪貼簿圖片'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('Android keyboard content becomes an image attachment', (
    tester,
  ) async {
    final clipboard = _Clipboard();
    final h = await _show(tester, clipboard);
    await tester.tap(_input);
    await tester.showKeyboard(_input);
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/textinput',
      const JSONMessageCodec().encodeMessage({
        'method': 'TextInputClient.performAction',
        'args': [
          -1,
          'TextInputAction.commitContent',
          {
            'mimeType': 'image/png',
            'uri': 'content://fixture/image.png',
            'data': _png.toList(),
          },
        ],
      }),
      (_) {},
    );
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    await tester.tap(find.byTooltip('送出'));
    await tester.pumpAndSettle();
    expect(
      (h.client.prompts.single['prompt'] as List).single['mimeType'],
      'image/png',
    );
    expect(clipboard.reads, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant({TargetPlatform.android}));

  testWidgets(
    'read failures show a safe message and release the loading state',
    (tester) async {
      final clipboard = _Clipboard()
        ..onRead = () => Future.error(
          PlatformException(code: 'denied', message: 'private native details'),
        );
      await _show(tester, clipboard);
      await tester.tap(find.byTooltip('附加'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('貼上剪貼簿圖片'));
      await tester.pumpAndSettle();
      expect(find.text('無法貼上剪貼簿圖片，請重新複製圖片後再貼上'), findsOneWidget);
      expect(find.textContaining('private native details'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'selected file bytes are uploaded and its resource is sent with the message',
    (tester) async {
      final bytes = Uint8List.fromList(utf8.encode('上傳內容'));
      final h = await _show(
        tester,
        _Clipboard(),
        pickFiles: () async => [
          XFile.fromData(bytes, name: '資料.txt', path: '資料.txt'),
        ],
      );
      await tester.enterText(_input, 'Read the attached file');
      await tester.tap(find.byTooltip('附加'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('上傳檔案'));
      await tester.pumpAndSettle();
      expect(h.client.uploads.single.sessionId, 'codex:one');
      expect(h.client.uploads.single.name, '資料.txt');
      expect(h.client.uploads.single.bytes, bytes);
      expect(find.text('資料.txt'), findsOneWidget);
      expect(tester.widget<TextField>(_input).focusNode!.hasFocus, isFalse);
      await tester.tap(find.byTooltip('送出'));
      await tester.pumpAndSettle();
      expect(h.client.prompts.single['prompt'], [
        {'type': 'text', 'text': 'Read the attached file'},
        {
          'type': 'resource_link',
          'name': '資料.txt',
          'uri': 'file:///workspace/資料.txt',
        },
      ]);
      expect(find.text('資料.txt'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final size in [const Size(320, 640), const Size(844, 390)]) {
    testWidgets('file progress and server acknowledgement fit $size', (
      tester,
    ) async {
      final bytes = Uint8List(5 * 1024 * 1024);
      final finished = Completer<Map<String, dynamic>>();
      UploadProgressCallback? progress;
      final h = await _show(
        tester,
        _Clipboard(),
        pickFiles: () async => [
          XFile.fromData(
            bytes,
            name: 'Generated Audio October 01.wav',
            path: 'Generated Audio October 01.wav',
          ),
        ],
      );
      tester.view.physicalSize = size;
      h.client.onUpload = (_, data, callback) {
        progress = callback;
        callback!(0, data.length);
        return finished.future;
      };
      await tester.enterText(_input, 'Read this');
      await tester.tap(find.byTooltip('附加'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('上傳檔案'));
      await tester.pumpAndSettle();
      progress!(bytes.length * 2 ~/ 5, bytes.length);
      await tester.pump();
      expect(find.text('40%'), findsOneWidget);
      expect(find.textContaining('MiB · 上傳中'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byKey(const ValueKey('file-upload-bar')),
            )
            .value,
        closeTo(.4, .001),
      );
      await tester.tap(find.byTooltip('送出'));
      expect(h.client.prompts, isEmpty);
      progress!(bytes.length, bytes.length);
      await tester.pump();
      expect(find.text('100%'), findsOneWidget);
      expect(find.textContaining('等待電腦確認'), findsOneWidget);
      expect(find.byTooltip('移除檔案'), findsNothing);
      finished.complete({
        'type': 'resource_link',
        'name': 'Generated Audio October 01.wav',
        'uri': 'file:///workspace/audio.wav',
      });
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('file-upload-progress')), findsNothing);
      expect(find.byTooltip('移除檔案'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'multiple files progress in order and retain successful files on failure',
    (tester) async {
      final bytes = Uint8List(100);
      final failed = Completer<Map<String, dynamic>>();
      UploadProgressCallback? progress;
      final h = await _show(
        tester,
        _Clipboard(),
        pickFiles: () async => [
          XFile.fromData(bytes, name: 'first.txt', path: 'first.txt'),
          XFile.fromData(bytes, name: 'second.wav', path: 'second.wav'),
        ],
      );
      h.client.onUpload = (name, data, callback) async {
        if (name == 'first.txt') {
          return {
            'type': 'resource_link',
            'name': name,
            'uri': 'file:///first.txt',
          };
        }
        progress = callback;
        callback!(25, data.length);
        return failed.future;
      };
      await tester.tap(find.byTooltip('附加'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('上傳檔案'));
      await tester.pumpAndSettle();
      expect(h.client.uploads.map((u) => u.name), ['first.txt', 'second.wav']);
      expect(find.text('2/2'), findsOneWidget);
      expect(find.text('25%'), findsOneWidget);
      expect(find.text('first.txt'), findsOneWidget);
      progress!(100, 100);
      await tester.pump();
      failed.completeError(const FormatException('Disk full'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('file-upload-progress')), findsNothing);
      expect(find.text('first.txt'), findsOneWidget);
      expect(find.text('second.wav'), findsNothing);
      expect(find.textContaining('檔案上傳失敗'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('late upload progress cannot enter another chat', (tester) async {
    final clipboard = _Clipboard();
    final finished = Completer<Map<String, dynamic>>();
    UploadProgressCallback? progress;
    final h = await _show(
      tester,
      clipboard,
      pickFiles: () async => [
        XFile.fromData(Uint8List(100), name: 'old.wav', path: 'old.wav'),
      ],
    );
    h.client.onUpload = (_, data, callback) {
      progress = callback;
      callback!(10, data.length);
      return finished.future;
    };
    await tester.tap(find.byTooltip('附加'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('上傳檔案'));
    await tester.pumpAndSettle();
    expect(find.text('10%'), findsOneWidget);
    final other = SessionController(h.client, 'codex:two');
    addTearDown(other.dispose);
    await tester.pumpWidget(_app(other, clipboard));
    progress!(100, 100);
    finished.complete({
      'type': 'resource_link',
      'name': 'old.wav',
      'uri': 'file:///old.wav',
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('file-upload-progress')), findsNothing);
    expect(find.text('old.wav'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('failed send restores the draft and uploaded file for retry', (
    tester,
  ) async {
    final h = await _show(
      tester,
      _Clipboard(),
      pickFiles: () async => [
        XFile.fromData(
          Uint8List.fromList([1, 2]),
          name: 'retry.txt',
          path: 'retry.txt',
        ),
      ],
    );
    h.client.failPrompt = true;
    await tester.enterText(_input, 'Keep this draft');
    await tester.tap(find.byTooltip('附加'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('上傳檔案'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('送出'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(_input).controller!.text,
      'Keep this draft',
    );
    expect(find.text('retry.txt'), findsOneWidget);
    h.client.failPrompt = false;
    await tester.tap(find.byTooltip('送出'));
    await tester.pumpAndSettle();
    expect(h.client.prompts, hasLength(1));
    expect(h.client.uploads, hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a queued send stays cleared after socket loss and remount', (
    tester,
  ) async {
    final clipboard = _Clipboard();
    final h = await _show(tester, clipboard);
    h.client.pendingPrompt = Completer<dynamic>();
    h.controller.timeline.state = 'running';
    await tester.enterText(_input, 'Queue this once');
    await tester.pump();
    await tester.longPress(
      find.widgetWithIcon(IconButton, Icons.arrow_upward_rounded),
    );
    await tester.pumpAndSettle();
    expect(h.client.prompts.single['_meta']['codeaw']['delivery'], 'queue');
    expect(tester.widget<TextField>(_input).controller!.text, isEmpty);
    h.client.pendingPrompt!.completeError(
      RpcError(RpcError.connectionClosed, 'Connection closed'),
    );
    await tester.pumpAndSettle();
    expect(h.controller.draft, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_app(h.controller, clipboard));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(_input).controller!.text, isEmpty);
    expect(h.client.prompts, hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('accepted queue never overwrites a new draft after disconnect', (
    tester,
  ) async {
    final clipboard = _Clipboard();
    final h = await _show(tester, clipboard);
    h.client.pendingPrompt = Completer<dynamic>();
    h.controller.timeline.state = 'running';
    await tester.enterText(_input, 'Already queued');
    await tester.pump();
    await tester.longPress(
      find.widgetWithIcon(IconButton, Icons.arrow_upward_rounded),
    );
    await tester.pumpAndSettle();
    final id = h.client.prompts.single['_meta']['codeaw']['clientPromptId'];
    h.controller.onMessage(
      SessionMessage('_codeaw/event', {
        'event': {
          'type': 'prompt_receipt',
          'promptId': id,
          'status': 'received',
        },
      }),
    );
    await tester.pumpAndSettle();
    await tester.enterText(_input, 'My next unsent draft');
    h.client.pendingPrompt!.completeError(
      RpcError(RpcError.connectionClosed, 'Connection closed'),
    );
    await tester.pumpAndSettle();
    final next = SessionController(h.client, 'codex:next');
    await tester.pumpWidget(_app(next, clipboard));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_app(h.controller, clipboard));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(_input).controller!.text,
      'My next unsent draft',
    );
    expect(h.controller.draft, 'My next unsent draft');
    expect(h.client.prompts, hasLength(1));
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpWidget(const SizedBox());
    next.dispose();
  });
}
