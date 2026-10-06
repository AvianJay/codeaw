# History, concurrent Live Activities and quota refresh verification

Initial verification on Windows on 2026-10-06. The real checks use Codex
`gpt-6-luna` with `low` reasoning; they do not use the fake test agent.

| Request | Cause and change | Evidence |
|---|---|---|
| Slow history | Desktop attach waited for complete older history; replay included large repeated tool output. Return the current snapshot immediately and defer bulky tool details until expansion. | Real desktop replay payload dropped from 25.1 MB to 5.1 MB, about 80%. Full deferred output exactly matched the original content, raw output and terminal bytes. Initial full load was 2.15 s and subsequent lazy load 0.20 s; cold/warm ordering means this is not a controlled mobile speed benchmark. |
| History disappears after restarting | Timelines and reconnect cursors lived only in memory. Persist complete snapshots and the session list per pairing, restore before networking, stage full replacements until complete. | Native cache restored 1,419 real timeline items offline with exact snapshot equality: write 155 ms, restore 93 ms on this PC. Browser reload with WebSockets blocked restored title and history from IndexedDB. Epoch changes, interrupted replay, eviction, corrupt files and host isolation have regression coverage. |
| Live Activity chat titles and multiple sessions | Only opened chats were followed; native ACP titles can arrive through session/list. Track all running activity snapshots and publish native list titles to existing sessions. | Two real Luna Low sessions ran overlapping 18-second PowerShell commands. A watcher that never opened either chat received both titles, command state, timestamps and completion. App tests cover unopened sessions and privacy redaction. iOS determines how many activities it displays. |
| Activity needs reopening after minutes | Keep the system timer and explicit last-sync time, and offer an optional background location session while work runs. | All content now has a 120-second stale date: the timer continues and stale activity displays “更新已暫停”. Location updates require explicit opt-in and When In Use permission; coordinates are discarded. APNs requires matching signing and PC credentials. Native compilation and physical iPhone delivery checks are separate. |
| Quota bars jump while refreshing | Each account completion changed the public average. Stage a full batch privately, retain previous values and commit once every account settles. | Tests delay individual accounts and verify both provider averages and timestamp change together. Failed/unknown/disabled accounts are excluded at the final commit; zero remains included. The existing 30-second foreground poller remains shared. |
| 5hr label | Header and usage averages used the English abbreviation. Display `5小時`. | Header/usage widget assertions cover the new label, provider separation and narrow landscape/portrait layouts. |

Initial local checks: bridge `npm test` (124 passed, 7 platform skips),
`npm run typecheck` and build passed. Flutter `flutter test` (162 passed,
12 optional skips) and `flutter analyze` passed. The real-cache fixture test
also passed when enabled separately. Flutter Web release build passed and
portrait/landscape browser screenshots were visually checked.

## Packaged long-chat transport follow-up

Opening or reconnecting to a long chat exposed another source of excess Android
traffic. Ordinary shell commands mentioning agent/task words bypassed deferred
output, medium tool outputs and duplicated input/title/Claude metadata stayed
inline, and deferred historical edits automatically downloaded their diffs.
Replay now uses structured collaboration identity, a 4 KiB deferral threshold,
bounded inline input/title metadata, and edit expansion only on request.

The packaged Bun WebSocket server ignores `permessage-deflate`, although Node
tests negotiate it. App clients explicitly opt into binary gzip JSON frames;
native and browser clients decode them before JSON-RPC handling. Older bridges
and clients without the opt-in retain text compatibility. Windows, Linux x64,
and macOS x64/arm64 CI now exercise the actual packaged executable.

The compiled Windows executable preserved an exact Chinese text response while
reducing its transfer from 390,227 to 2,560 bytes. A real desktop history fixture
transferred 43.31 MB in full and 2.38 MB with deferred history and gzip. Exact
tool output/title/input hydration passed, and a same-epoch reconnect transferred
1,030 bytes. The actual native App transport restored 3,036 timeline items and
the durable cursor from disk; reconnect replayed zero history entries. Earlier
installed lazy replay was about 11 MB. These are PC-local byte measurements;
they do not establish a mobile throughput rate or prove Android device behavior.
The reported phone symptom is **1.8 MB/s**, not 11.8 MB/s.

Current local checks passed: bridge `npm test` (184 passed, 7 skipped),
`npm run typecheck`, Flutter `flutter test` (237 passed, 12 skipped), and analysis
of changed Flutter files. The native transport test and real history test use
the actual Codex history, separately from the fake-agent unit checks. Update
both App and bridge to enable gzip, then verify cold long-chat opening and
reconnection on the Android handset. Background location and retained-activity
startup also still require physical iPhone verification.

## Confirmed chat deletion

The chat list has a Delete button and the chat menu has the same action. Both
require confirmation before sending the request. Cancelling sends no deletion;
failed requests preserve history. Running/queued chats reject deletion without
cancelling their work. Desktop-linked chats are removed only from Codeaw, and
the confirmation explains that their Codex desktop conversation remains.
Project directories and uploaded files remain on the PC.

Deletion markers persist on the bridge so agents retaining their own transcripts
cannot resurrect removed chats through refresh, reconnect or restart. The App
also removes its list entry and cache, and suppresses stale list responses and
late disposal saves. Bridge tests cover restart, retained native history, files
remaining intact and desktop ownership; six App tests cover explicit confirmation,
cancellation, failure, cache restoration, navigation and small portrait/landscape
screens. Two dedicated real Luna Low chats ran commands, completed and were
deleted successfully; subsequent listing omitted them and reopening was rejected.

## Reproduce without changing the primary desktop chat

```powershell
cd bridge
node --import tsx scripts/history-real-e2e.ts --cwd <workspace> --session codex:<existing-id> --report <PC-local-report.json>
# After installing the new bridge:
node --import tsx scripts/history-real-e2e.ts --installed --cwd <workspace> --session codex:<existing-id> --report <PC-local-report.json>
```

The existing desktop chat is only subscribed to, replayed, hydrated and detached;
it is never prompted, cancelled or closed. The test creates two separate chats
for real generation, waits for their completion, closes those test chats and
revokes its temporary pairing. `--history-only` omits generation.
`--fixture <PC-local-path>` exports a private transcript fixture; never commit
that file. Enable the offline native test with
`CODEAW_REAL_HISTORY_FIXTURE=<PC-local-path>` and run
`flutter test test/history_real_cache_test.dart` in `app`.

On iPhone check restart/offline history, expansion of a long tool output,
portrait/landscape with the keyboard, upload and image zoom, LCSign import/sign/
install, scroll-to-bottom, and two simultaneous Lock Screen activities. For
local-only signing check the continuing timer and last-sync label after several
minutes locked. For APNs check that a changed command and completion actually
arrive while locked; a successful build or a Push-capable profile does not prove
delivery. Setup is in [live-activities.md](live-activities.md).
