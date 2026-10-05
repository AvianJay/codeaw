# Mobile regressions: verification record

Verified on Windows on 2026-10-05 with the installed NSIS bridge. Real inference
used `gpt-6-luna` with `low` reasoning, confirmed in Codex's `turn_context`
records. Unit/widget tests use fixtures; the real tests below do not launch a
fake agent. Native iPhone behavior remains a device verification step.

| Item | Root cause | Fix | Verification |
|---|---|---|---|
| 1. Desktop settings | Desktop load returned no options and setters were rejected | Expose model, effort, permission and collaboration controls; route changes to the existing owner and confirm its state | Real owner switched models, effort, read-only/Agent/full-access and Default/Plan; model and effort changed during generation without replacing the current turn. Phone-size Web UI changed effort and returned without focusing the composer |
| 2. Landscape | Width-only tablet detection added rail, padding, large input and desktop hints to landscape phones | Use shortest-side checks and a compact composer/toolbar | Widget tests at 844×390 and 667×375, with 180 px keyboard inset and multiline input, retained >60 px of chat. Real Web UI at CSS 844×390 displayed chat and composer |
| 3. Keyboard | Focus survived controller/navigation changes, modal restoration and missing touch/drag dismissal | Unfocus old input, prevent modal focus restoration, add tap-outside/drag/Done dismissal, read actual view insets after Scaffold resizing | iOS-platform widget tests exercised Done, outside tap, drag and session switch. Native iOS keyboard still needs verification |
| 4. Upload | No general file picker or authenticated upload endpoint | Native picker, bounded raw upload, unique local storage and resource-link prompt; retry retains draft/attachments | Widget picker/bytes/retry tests; HTTP binary/hash/auth/limit tests; real ACP and desktop Codex read unique contents; actual Web picker→upload→Luna reply returned `CODEAW_BROWSER_UPLOAD_OK` |
| 5. PowerShell | PSReadLine interpreted LF as continuation instead of Enter | Normalize Windows LF/CRLF writes to CR | Original installed bridge produced `>>` for LF and executed CR. Updated installed bridge executed LF and reported the correct cwd; regression test also checks multiline and Chinese output |
| 6. Other drives | Browser/session paths limited to configured/known roots; session/new did not validate cwd first | PC-only `filesystem.allowAllPaths` opt-in, drive roots and upfront directory validation | Default denied C: root and missing cwd. Opt-in enumerated C:/D:/E:/G:/H:, browsed C:/E: and ran real Luna Low in a C: test folder. Opt-in was disabled afterward. Fixture test checks junction containment |
| 7. LCSign | Installer choice returned an HTTPS browser URL | `loadcontroller://import?url=…` and iOS scheme query declaration | Scheme and percent encoding tested; official LCSign 1.3 IPA's Info.plist/localized instructions inspected statically. Launch/import/sign/install on iPhone remains unverified |
| 8. Steering | Desktop steer omitted required `restoreMessage`; owner read undefined cwd; newer replies are nested | Supply restore context and unwrap accepted result; propagate ambiguous delivery errors without starting a replacement turn | Before fix the real owner rejected missing cwd. After fix a real read-only 15-second command received a follow-up in the same turn, queued=0, final answer `CODEAW_STEER_ACCEPTED`; native turn count increased by exactly one |

Local checks: bridge `npm test` (89 tests), `npm run typecheck`, Flutter
`flutter test` (116 passed, 11 optional tests skipped), and `flutter analyze`.
Windows settings were rendered with `npm run smoke:desktop`; the opt-in and
security explanation were fully visible. Flutter web and NSIS builds succeeded.

## Reproducing real tests

Use an already-running bridge and a temporary paired test device. Store its
`{"token":"…"}` in a private file outside the repository; never publish it.
The following commands spend real Codex tokens:

```powershell
cd bridge
npx tsx scripts/real-e2e.ts --auth <private-token.json> --cwd <allowed-workspace> --phase acp --report <private-report.json>
# Open the resulting dedicated test session in Codex desktop, then:
npx tsx scripts/real-e2e.ts --auth <private-token.json> --cwd <workspace> --phase desktop --session codex:<test-id> --report <private-report.json>
# Enable filesystem.allowAllPaths on the PC, after warning connected users of a restart:
npx tsx scripts/real-e2e.ts --auth <private-token.json> --cwd <existing-C-drive-test-folder> --phase filesystem --report <private-report.json>
```

If the ACP adapter bundles an older Codex without GPT 6 Luna, its documented
`agents.codex.env.CODEX_PATH` override can use the current desktop's `codex.exe`
for these tests. Back up/restore that override. Do not substitute an older Luna
model. The desktop phase must target a dedicated test conversation; do not point
it at a user's active work. Restore filesystem opt-in after testing and revoke
temporary device tokens. Restart/installation warnings apply to every repeat.

On iPhone verify landscape with the keyboard, dismissal and navigation,
Files/iCloud/photo permissions and attachment delivery, and the LCSign
download/import/sign/install flow. LCSign's scheme imports the IPA; signing is
still completed in LCSign using the original certificate and bundle identifier.
