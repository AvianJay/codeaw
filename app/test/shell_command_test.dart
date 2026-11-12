import 'package:codeaw/data/bridge_client.dart';
import 'package:codeaw/data/host.dart';
import 'package:codeaw/data/session_controller.dart';
import 'package:codeaw/data/tool_display.dart';
import 'package:codeaw/ui/chat/items.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Reproduce the quoted launcher path and doubled backslashes with fixture paths.
const _runtime =
    r'"C:\\Program Files\\WindowsApps\\CodexRuntime\\powershell\\pwsh.exe"';
const _status = '$_runtime -Command \'git status --short --branch; git remote -v\'';
const _search =
    '$_runtime -Command "Get-Location; rg -n -i \'feature|fixture\' \'C:\\\\Users\\\\fixture\\\\project\'"';

void main() {
  test('a command is shown without the shell that launched it', () {
    expect(shellCommand(_status), 'git status --short --branch; git remote -v');
    expect(
      shellCommand(_search),
      r"Get-Location; rg -n -i 'feature|fixture' 'C:\Users\fixture\project'",
    );
    expect(
      shellCommand("\"C:\\Users\\fixture\\.cache\\runtime\\pwsh.exe\" -NoProfile -ExecutionPolicy Bypass -Command 'Write-Output ''it''s'''"),
      "Write-Output 'it's'",
    );
    expect(shellCommand("/bin/bash -lc 'cd app && flutter test'"), 'cd app && flutter test');
    expect(shellCommand('cmd.exe /c dir /b'), 'dir /b');
    expect(shellCommand(r'bash -c "echo \"hi\""'), 'echo "hi"');
    // Not a wrapper: the command is what was typed.
    for (final plain in [
      'git status',
      r'powershell -NoProfile -File scripts\prod\install.ps1 -Uninstall; Remove-Item .next',
      r"& 'C:\altera\quartus_sim.exe' 7483_2S -c 7483_2S",
      'python -c "print(1)"',
      "node -e 'console.log(1)'",
      'Terminal',
      '',
    ]) {
      expect(shellCommand(plain), plain, reason: plain);
    }
    expect(toolTitle(title: _status), 'git status --short --branch; git remote -v');
  });

  testWidgets('a command row leads with its purpose and never with a launcher path', (tester) async {
    final c = SessionController(
      BridgeClient(HostConfig(name: 'test', urls: ['ws://localhost:1'], token: 'test', deviceId: 'test', deviceName: 'test')),
      'codex:test',
    );
    addTearDown(c.dispose);
    void call(String id, String title, Map<String, dynamic> rawInput) {
      c.timeline.apply('session/update', {
        'update': {'sessionUpdate': 'tool_call', 'toolCallId': id, 'title': title, 'kind': 'execute', 'status': 'completed', 'rawInput': rawInput},
      });
    }

    call('codex', _status, {'command': _status, 'cwd': r'E:\repo'});
    call('claude', 'flutter analyze 2>&1 | Select-Object -Last 30', {
      'command': 'flutter analyze 2>&1 | Select-Object -Last 30',
      'description': 'Run flutter analyze',
      'timeout': 600000,
    });
    c.timeline.flush();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(children: [
            for (final item in c.timeline.rootItems) TimelineItemView(key: ValueKey(item.key), item: item, controller: c, isLast: false),
          ]),
        ),
      ),
    );
    expect(find.textContaining('WindowsApps'), findsNothing);
    expect(find.textContaining('pwsh.exe'), findsNothing);
    final codex = tester.widget<RichText>(find.textContaining('git status --short --branch', findRichText: true));
    expect(codex.text.style?.fontFamily, 'monospace');
    // Claude says what the command is for; that leads, the command follows.
    final purpose = tester.getTopLeft(find.text('Run flutter analyze'));
    final command = tester.getTopLeft(find.textContaining('flutter analyze 2>&1', findRichText: true));
    expect(purpose.dy, lessThan(command.dy));

    // Opened, the full command is still there to read, minus the launcher.
    await tester.tap(find.textContaining('git status --short --branch', findRichText: true));
    await tester.pumpAndSettle();
    expect(find.textContaining('WindowsApps', findRichText: true), findsNothing);
    expect(find.textContaining(r'$ git status --short --branch; git remote -v', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
