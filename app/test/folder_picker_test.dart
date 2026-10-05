import 'package:codeaw/app_state.dart';
import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/ui/common/app_theme.dart';
import 'package:codeaw/ui/sessions/new_session_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
  }
  final calls = <Map<String, dynamic>>[];
  bool duplicate = false;
  @override
  void start() {}
  @override
  Future<dynamic> request(String method, [Map<String, dynamic>? params]) async {
    if (method == '_codeaw/fs/list') {
      return {'path': params!['path'], 'entries': []};
    }
    if (method == '_codeaw/fs/mkdir') {
      calls.add(params!);
      if (duplicate) throw StateError('同名檔案或資料夾已存在');
      return {'path': '${params['path']}/${params['name']}'};
    }
    return {};
  }
}

void main() {
  testWidgets(
    'browse creates a folder, enters it, and returns it as session cwd',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final client = _Client();
      final state = AppState(HostStore(), openSession: (_) {})..client = client;
      String? selection;
      await tester.pumpWidget(
        AppScope(
          state: state,
          child: MaterialApp(
            theme: codeawTheme(Brightness.light),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    selection = await Navigator.push<String>(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            const FolderPickerPage(start: 'C:/Projects'),
                      ),
                    );
                  },
                  child: const Text('瀏覽…'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('瀏覽…'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('新增資料夾'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '..');
      await tester.tap(find.text('建立'));
      await tester.pumpAndSettle();
      expect(client.calls, isEmpty);
      expect(find.text('請使用有效的資料夾名稱'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField), '新的專案');
      await tester.tap(find.text('建立'));
      await tester.pumpAndSettle();
      expect(client.calls.single, {'path': 'C:/Projects', 'name': '新的專案'});
      expect(find.text('新的專案'), findsOneWidget);
      await tester.tap(find.text('選這裡'));
      await tester.pumpAndSettle();
      expect(selection, 'C:/Projects/新的專案');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );

  testWidgets('duplicate folder keeps the dialog open and explains the error', (
    tester,
  ) async {
    final client = _Client()..duplicate = true;
    final state = AppState(HostStore(), openSession: (_) {})..client = client;
    await tester.pumpWidget(
      AppScope(
        state: state,
        child: MaterialApp(home: const FolderPickerPage(start: 'C:/Projects')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('新增資料夾'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'already-there');
    await tester.tap(find.text('建立'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('同名檔案或資料夾已存在'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });
}
