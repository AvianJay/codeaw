import 'dart:async';

import 'package:codeaw/acp/jsonrpc.dart';
import 'package:codeaw/app_state.dart';
import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/file_download.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/ui/files/file_view_page.dart';
import 'package:codeaw/ui/files/files_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const root = 'D:/Miku Music', wave = '$root/Negi_Rocket.wav';

class _Client extends BridgeClient {
  _Client()
    : super(
        HostConfig(
          name: 'PC',
          urls: ['ws://localhost/acp'],
          token: 'fixture',
          deviceId: 'fixture',
          deviceName: 'fixture',
        ),
      ) {
    status = ConnStatus.online;
    supportsFileArchives = true;
  }
  final calls = <Map<String, dynamic>>[];
  CancelToken? cancel;
  Completer<DownloadedFile>? pending;
  int disposed = 0;
  @override
  void start() {}
  @override
  Future<dynamic> request(String method, [Map<String, dynamic>? params]) async {
    if (method == '_codeaw/fs/read') {
      return {'binary': true, 'size': 8616268, 'mimeType': 'audio/wav'};
    }
    if (method == '_codeaw/fs/list') {
      return {
        'path': params!['path'],
        'entries': [
          {
            'path': wave,
            'name': 'Negi_Rocket.wav',
            'type': 'file',
            'size': 8616268,
          },
          {
            'path': '$root/歌詞.txt',
            'name': '歌詞.txt',
            'type': 'file',
            'size': 948,
          },
          {'path': '$root/曲目', 'name': '曲目', 'type': 'dir'},
        ],
      };
    }
    return {};
  }

  Future<DownloadedFile> _download(
    String name,
    DownloadProgress? progress,
    CancelToken? token,
  ) {
    cancel = token;
    progress?.call(50, 100);
    return pending?.future ??
        Future.value(
          DownloadedFile(
            path: '/tmp/$name',
            name: name,
            size: 100,
            mimeType: name.endsWith('.zip') ? 'application/zip' : 'audio/wav',
            dispose: () async {
              disposed++;
            },
          ),
        );
  }

  @override
  Future<DownloadedFile> downloadFile(
    String path, {
    required String name,
    DownloadProgress? onProgress,
    CancelToken? cancel,
  }) {
    calls.add({'file': path});
    return _download(name, onProgress, cancel);
  }

  @override
  Future<DownloadedFile> downloadArchive(
    String path,
    List<String> paths, {
    required String name,
    DownloadProgress? onProgress,
    CancelToken? cancel,
  }) {
    calls.add({'path': path, 'paths': paths});
    return _download(name, onProgress, cancel);
  }
}

void main() {
  Future<AppState> show(
    WidgetTester tester,
    _Client client,
    Widget page, {
    Size size = const Size(390, 844),
    double scale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(HostStore(), openSession: (_) {})..client = client;
    await tester.pumpWidget(
      AppScope(
        state: state,
        child: MaterialApp(
          theme: ThemeData.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: page,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return state;
  }

  Future<void> finish(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  }

  testWidgets(
    'WAV can download and opens native share menu with the file and popover origin',
    (tester) async {
      final client = _Client();
      final state = await show(tester, client, const FileViewPage(path: wave));
      MethodCall? share;
      const channel = MethodChannel('dev.fluttercommunity.plus/share');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        share = call;
        return 'success';
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      expect(find.text('下載檔案'), findsOneWidget);
      await tester.tap(find.byTooltip('分享檔案'));
      await tester.pumpAndSettle();
      expect(client.calls.single, {'file': wave});
      expect(find.text('檔案已備妥'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilledButton, '分享檔案'),
        ),
      );
      await tester.pumpAndSettle();
      expect(share?.method, 'share');
      expect(share?.arguments['paths'], ['/tmp/Negi_Rocket.wav']);
      expect(share?.arguments['mimeTypes'], ['audio/wav']);
      expect(share?.arguments['originWidth'], greaterThan(0));
      expect(client.disposed, 1);
      expect(tester.takeException(), isNull);
      await finish(tester, state);
    },
  );

  testWidgets(
    'download opens native save picker using a file path and original name',
    (tester) async {
      final client = _Client();
      final state = await show(tester, client, const FileViewPage(path: wave));
      MethodCall? save;
      const channel = MethodChannel('flutter_file_dialog');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        save = call;
        return '/files/saved.wav';
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await tester.tap(find.byTooltip('下載檔案'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('儲存檔案'));
      await tester.pumpAndSettle();
      expect(save?.method, 'saveFile');
      expect(save?.arguments['sourceFilePath'], '/tmp/Negi_Rocket.wav');
      expect(save?.arguments['fileName'], 'Negi_Rocket.wav');
      expect(save?.arguments['data'], isNull);
      expect(client.disposed, 1);
      await finish(tester, state);
    },
  );

  testWidgets(
    'select files and folders to ZIP, clear selection, and fit landscape with large text',
    (tester) async {
      final client = _Client();
      final state = await show(
        tester,
        client,
        const FilesPage(path: root),
        size: const Size(844, 390),
        scale: 1.4,
      );
      await tester.tap(find.byTooltip('選取檔案'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Negi_Rocket.wav'));
      await tester.tap(find.text('歌詞.txt'));
      await tester.pumpAndSettle();
      expect(find.text('已選取 2 個項目'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('打包 ZIP 下載'));
      await tester.pumpAndSettle();
      expect(client.calls.single, {
        'path': root,
        'paths': [wave, '$root/歌詞.txt'],
      });
      expect(find.text('Miku Music.zip'), findsOneWidget);
      await tester.tap(find.text('關閉'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('全選'));
      await tester.pumpAndSettle();
      expect(find.text('已選取 3 個項目'), findsOneWidget);
      await tester.tap(find.byTooltip('取消選取'));
      await tester.pumpAndSettle();
      expect(find.byType(Checkbox), findsNothing);
      expect(find.byTooltip('新增資料夾'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await finish(tester, state);
    },
  );

  testWidgets(
    'download progress can be cancelled and a late file is cleaned up',
    (tester) async {
      final client = _Client()..pending = Completer<DownloadedFile>();
      final state = await show(tester, client, const FileViewPage(path: wave));
      await tester.tap(find.byTooltip('下載檔案'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('50%'), findsOneWidget);
      await tester.tap(find.text('取消下載'));
      await tester.pumpAndSettle();
      expect(client.cancel?.isCancelled, true);
      client.pending!.complete(
        DownloadedFile(
          path: '/tmp/late.wav',
          name: 'late.wav',
          size: 100,
          mimeType: 'audio/wav',
          dispose: () async {
            client.disposed++;
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(client.disposed, 1);
      expect(tester.takeException(), isNull);
      await finish(tester, state);
    },
  );

  testWidgets('older bridge explains why ZIP is unavailable', (tester) async {
    final client = _Client()..supportsFileArchives = false;
    final state = await show(tester, client, const FilesPage(path: root));
    await tester.tap(find.byTooltip('選取檔案'));
    await tester.tap(find.text('Negi_Rocket.wav'));
    await tester.pumpAndSettle();
    expect(find.text('請先更新電腦端 bridge 以使用 ZIP'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '打包 ZIP 下載'))
          .onPressed,
      isNull,
    );
    await finish(tester, state);
  });
}
