# CPA usage, appearance and folder creation

Implemented on Windows on 2026-10-05. The earlier eight mobile regressions are
recorded separately in `mobile-regression-verification.md` and remain covered
by the full regression suite.

| Request | Cause / implementation | Verification |
|---|---|---|
| CPA endpoint and usage viewer | No CPA connection, management adapter or usage route existed. Add device secure settings and paired bridge queries for v0/v8 management APIs | Bridge tests cover URL normalization, authentication, secret stripping, optional credits failures, disabled/unsupported accounts and request routing. Controller tests cover persistence, errors and stale replies |
| Compact account lines | Add provider icons, search/filter, thin quota lines, remaining percentages, local reset time/countdown and actual Codex reset credits | Widget tests at 320×640, 390×844, 844×390 and 1200×800; real browser at 390×844 and 844×390. Browser testing found and fixed a missing callback invocation in the filter |
| UI and icons | Shared neutral/indigo theme, softer agent icons, cleaner composer/settings controls, usage navigation and saved system/light/dark preference | Full layout/composer/navigation regression suite; browser screenshots of light/dark usage and settings. Grok SVG source and MIT attribution included |
| New folder after 瀏覽… | Picker had only list/select operations and the bridge had no mkdir extension. Add create action to picker and file page | Widget browse→Chinese name→enter→select test; duplicate/error retention; bridge creation/list/session, invalid name, junction containment and opt-in tests. Actual browser created a Chinese-named directory on Windows and returned it to the new-session sheet |
| Provider averages and quota colors | Independent weekly/5小時 account averages, one decimal, no special-allowance mixing; green/yellow/red reflect remaining quota | Exact `(97+23+20)/3 = 46.7%`, independent providers/windows, AGY equal account weight, unknown/zero/disabled cases, 20/50 color boundaries in both themes |
| Chat-header bars | Usage was only visible on the usage page. Add compact weekly/5小時 bars beside the title using the current agent's provider, keeping the usage page averages | Header tests at 320×640, 390×844 and 844×390, provider changes, unknown states, click-through and shared polling |
| Refresh every 30 seconds | Move polling into a shared controller bound to the selected bridge | Foreground/background/resume, no overlapping requests, header/page single poller, host-switch regression |
| Queued draft reappears | Prompt RPC lasts until turn end; connection-close restored possibly accepted text. Long-press Tooltip also stole queue gestures | Real long-press widget test, receipt-before-turn-completion, socket loss/remount/switch-chat/new draft, uncertain replay ordering and disposed-controller late errors |
| Single/double check marks | Separate bridge acceptance from AI processing, persist receipt states and correlate native desktop prompt ids | Queue/disconnect/replay/deduplication bridge tests; receipt icons; native steering id replay; real Luna Low desktop-linked tests |
| Uploaded image enlargement | ACP BlockImage had no onTap, unlike Markdown images | Shared full-screen preview; own-image tap, double-tap zoom, drag, reset and close tests; authenticated blob source uses the same image provider |

Local checks after integration with the macOS changes: bridge `npm test`
(108 passed, 7 platform tests skipped on Windows), `npm run typecheck`, Flutter
`flutter test` (149 passed, 11 optional tests skipped), `flutter analyze` with
no issues, and release Web build. Unit/widget checks use test fixtures.

Browser CPA validation used a local HTTP management fixture with representative
Codex/Claude/Grok/Antigravity responses through the actual source bridge and
Flutter release Web app. It verified saved settings, key masking, provider
identification, separate quota windows, reset credits, search, type filters,
refresh and explicit unsupported quota behavior. It did not contact a live
CPA deployment, redeem credits, or send model requests. Live service access
needs the user's configured endpoint and Management Key; never paste keys
into an issue or chat.

The follow-up was also tested through a running source bridge with real Codex
desktop inference, `gpt-6-luna` and `low` effort, in a dedicated test conversation.
A read-only PowerShell sleep kept a turn running while a follow-up was queued
or steered. Checks verified received-before-read for queueing, immediate read
for accepted steering, reconnect/full replay, same-id deduplication, the actual
model's unique response marker and return to idle. The real steering snapshot
exposed the missing `clientUserMessageId` correlation; reading that field fixed
receipt persistence after reconnect. Browser testing pasted a public test PNG,
sent it to the same real model and opened the uploaded image in full screen.
Reload testing found the replay compactor copied `partIndex: 0` to every image
part, erasing the caption. Distinct replay part indexes now retain text/images,
and the latest steering/queue flags also survive compaction.
Header screenshots covered 320/390 px portrait and 844 px landscape. CPA quota
values in these browser checks came from the local management fixture.

Installed-build tests also caught a regression from the merged macOS work:
the new ACP command check read `PATH` from a copied Windows environment whose
key was `Path`, rejecting an installed npm command shim. Command discovery now
keeps Windows environment key lookups case-insensitive; tests cover the copied
environment and an explicit PATH override. The final packaged bridge is tested
again with real Codex, independently of the fake-agent checks.

CPA API behavior was checked against [CLIProxyAPI management documentation](https://help.router-for.me/management/api)
and [the official management UI](https://github.com/router-for-me/Cli-Proxy-API-Management-Center/tree/ee79a794526a30c03748a8864a9ac6589a31833b).
Quota endpoints are service-provider interfaces and can change. Unknown or
unavailable values stay unknown; a passed reset timestamp is not treated as
proof of replenishment. “Reset count” means actual available credits, not an
estimate of future five-hour windows.

On iPhone, install the new nightly IPA and verify:

1. Settings → CPA usage: enter the real CPA endpoint and Management Key;
   compare account types, percentages, reset times and actual credits with
   CPA's own management page. The PC performs network access.
2. Portrait/landscape, system/light/dark theme, filtering and refresh.
   Check the bars beside the chat title, 30-second updates and provider changes;
   compare the unchanged usage-page averages with real accounts.
3. New chat → Browse → parent directory → new-folder icon → Chinese name →
   Create → Select here → start chat. Repeat from the project file page.
4. The earlier native keyboard dismissal, landscape with the keyboard,
   Files/iCloud attachment picker, and LCSign import/sign/install checks.
5. Long-press Send to queue, then switch chats or background/foreground the app:
   old sent text must stay out of the composer, and a new draft must survive.
   Confirm one check while queued and two once AI begins processing.
6. Tap your own uploaded image, pinch/drag/double-tap, reset and close. Repeat
   after reconnect, when the image is fetched as an authenticated bridge blob.

Native iOS behavior and a live CPA deployment cannot be established by widget
fixtures or a successful IPA build alone.
