# History, concurrent Live Activities and quota refresh verification

Verified on Windows on 2026-10-06. The real checks use Codex
`gpt-6-luna` with `low` reasoning; they do not use the fake test agent.

| Request | Cause and change | Evidence |
|---|---|---|
| Slow history | Desktop attach waited for complete older history; replay included large repeated tool output. Return the current snapshot immediately and defer bulky tool details until expansion. | Real desktop replay payload dropped from 25.1 MB to 5.1 MB, about 80%. Full deferred output exactly matched the original content, raw output and terminal bytes. Initial full load was 2.15 s and subsequent lazy load 0.20 s; cold/warm ordering means this is not a controlled mobile speed benchmark. |
| History disappears after restarting | Timelines and reconnect cursors lived only in memory. Persist complete snapshots and the session list per pairing, restore before networking, stage full replacements until complete. | Native cache restored 1,419 real timeline items offline with exact snapshot equality: write 155 ms, restore 93 ms on this PC. Browser reload with WebSockets blocked restored title and history from IndexedDB. Epoch changes, interrupted replay, eviction, corrupt files and host isolation have regression coverage. |
| Live Activity chat titles and multiple sessions | Only opened chats were followed; native ACP titles can arrive through session/list. Track all running activity snapshots and publish native list titles to existing sessions. | Two real Luna Low sessions ran overlapping 18-second PowerShell commands. A watcher that never opened either chat received both titles, command state, timestamps and completion. App tests cover unopened sessions and privacy redaction. iOS determines how many activities it displays. |
| Activity needs reopening after minutes | A local-only activity expired after two minutes even though no background push was available. Keep the system timer with an explicit last-sync time in local-only mode. | Widget source uses no staleDate for local-only mode. APNs mode retains a stale deadline and becomes active only after token registration. Native compilation and physical iPhone checks are separate; true updates after suspension still require matching APNs signing and PC credentials. |
| Quota bars jump while refreshing | Each account completion changed the public average. Stage a full batch privately, retain previous values and commit once every account settles. | Tests delay individual accounts and verify both provider averages and timestamp change together. Failed/unknown/disabled accounts are excluded at the final commit; zero remains included. The existing 30-second foreground poller remains shared. |
| 5hr label | Header and usage averages used the English abbreviation. Display `5小時`. | Header/usage widget assertions cover the new label, provider separation and narrow landscape/portrait layouts. |

Local checks: bridge `npm test` (124 passed, 7 platform skips),
`npm run typecheck` and build passed. Flutter `flutter test` (162 passed,
12 optional skips) and `flutter analyze` passed. The real-cache fixture test
also passed when enabled separately. Flutter Web release build passed and
portrait/landscape browser screenshots were visually checked.

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
