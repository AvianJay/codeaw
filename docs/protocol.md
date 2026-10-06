# codeaw bridge protocol

The bridge is an **ACP v1 agent over WebSocket** (the WebSocket profile of the
ACP "Streamable HTTP & WebSocket Transport" RFD) that fronts several real ACP
agents running over stdio on the same machine. Every message is plain ACP v1
JSON-RPC; everything codeaw adds lives in ACP extension points:

- `_meta.codeaw` objects on standard requests, responses and notifications
- extension methods / notifications whose names start with `_codeaw/`

A generic ACP client can use the bridge as a normal agent. The codeaw app uses
the extensions for durability (replay after reconnect), multi-device sync and
the extra screens (files, git, pairing).

## Transport and auth

| Endpoint | Purpose | Auth |
|---|---|---|
| `GET /acp` (WebSocket upgrade) | ACP JSON-RPC, one text frame per message | `Authorization: Bearer <deviceToken>` (browsers may use `?token=`) |
| `POST /api/pair` | exchange a one-time pairing code for a device token | pairing code in body |
| `GET /api/health` | liveness, version | none |
| `GET /api/device` | validate the saved device token; returns `deviceId` | Bearer |
| `GET /api/blobs/<sha256>` | image bytes referenced from the event log | Bearer |
| `GET /api/fs/raw?path=<abs path>` | raw file bytes (image preview) | Bearer |
| `POST /api/uploads?sessionId=<id>&name=<filename>` | upload attachment bytes, at most 20 MiB | Bearer |

The server pings every 20 s and drops sockets that miss two pongs. Clients
should also ping and reconnect with exponential backoff.

### Pairing

`codeaw-bridge pair` (or the first start without paired devices) prints a QR
code containing

```
codeaw://pair?u=<ws url>&u=<alt ws url>...&c=<code>&n=<host name>
```

The code is 8 characters (shown as `XXXX-XXXX`), single use, valid 5 minutes.

```
POST /api/pair  {"code":"K7QM2XWD","deviceName":"Pixel 9"}
200 {"deviceId":"d_...","token":"<64 hex>","bridge":{"name":"my-pc","version":"0.1.0"}}
```

Only the SHA-256 of the token is stored on the bridge. Devices are listed and
revoked with `codeaw-bridge devices`.

## Session ids

External session id = `<agentId>:<agent's own session id>`, e.g.
`claude:7fd23c2b-494b-44e5-a5d3-c7602ca708fd`. Treat it as opaque.

## initialize

The response is a normal `InitializeResponse` with

```jsonc
"_meta": { "codeaw": {
  "version": 1,
  "host": "my-pc",
  "agents": [ AgentInfo, ... ]
}}
```

```jsonc
// AgentInfo
{
  "id": "claude", "name": "Claude Code",
  "status": "stopped" | "starting" | "ready" | "error",
  "error": "spawn failed ...",          // when status = error
  "agentInfo": { "name": "...", "version": "..." },  // from the agent, once started
  "capabilities": { /* the agent's agentCapabilities, once started */ },
  "steering": true                       // agent supports mid-turn steering
}
```

## Session lifecycle

### `session/new`

Params: standard (`cwd`, `mcpServers` — the bridge always sends `[]` to the
agent) plus

```jsonc
"_meta": { "codeaw": {
  "agentId": "claude",                       // required unless only one agent is configured
  "initialConfig": { "mode": "default" }     // optional: set_config_option calls applied right after creation
}}
```

Response: the agent's `NewSessionResponse` with `sessionId` rewritten and
`models` removed, plus `_meta.codeaw = { agentId, lastSeq, epoch }`.

### `session/load` (attach + replay)

Params: standard plus optional `_meta.codeaw.afterSeq`, `_meta.codeaw.epoch`,
and `_meta.codeaw.lazyHistory: true`.

1. The bridge first sends `_codeaw/replay` `{sessionId, mode: "full"|"delta", epoch}`.
   - `delta` when the client passed `afterSeq` and the same `epoch`: only log
     entries with `seq > afterSeq` follow in log order, with the negotiated
     deferred-output projection when `lazyHistory` is enabled.
   - `full` otherwise: the client stages a replacement timeline; a **compacted**
     history follows (message chunks merged, tool calls folded into their final
     state, terminal output concatenated, snapshot-type updates reduced to the
     last one).
     Keep the previous visible history and cursor until the load response or a
     matching `mode: "complete"` boundary arrives; discard an interrupted replacement.
2. Replayed entries are sent as `session/update` / `_codeaw/event`
   notifications carrying their `seq` (see below).
3. The response is sent after the replay:
   `{ modes?, configOptions?, _meta: { codeaw: { agentId, lastSeq, epoch, state, queued, turnStartedAt?, turnPromptId? } } }`.
   `turnStartedAt` is the running turn's Unix start time in milliseconds, unchanged
   while waiting for permission, steering or queueing another prompt.
4. Pending permission / elicitation requests are then (re)sent to this client.

From then on the connection is **attached**: every new log entry is pushed to it.

If the bridge has no log for the session (it was created outside codeaw, e.g.
in a terminal), it imports it first through the agent's own `session/load`.

`session/resume` attaches without any replay and returns the same response.

For a desktop-owned Codex conversation on Windows, load/resume subscribes to the
existing desktop owner over private IPC. It does not resume the same thread in
another app-server process. The external session id is unchanged. The response
adds `_meta.codeaw.connection: "desktop"` and `desktopConnected: boolean`.
These fields are also included in state events and activity notifications.

The desktop's snapshot and revisioned patches are authoritative. A historical
edit or newly loaded older history can trigger a new epoch and a live full
replay. Such a replay ends with `_codeaw/replay` `{mode: "complete", epoch,
lastSeq}`; clients clear their replay flag and advance the cursor at this
boundary without waiting for a load response. Duplicate/replayed text is not
appended twice.

Desktop attach returns the owner's current snapshot immediately. If older turns
are incomplete, the bridge requests them in the background and delivers the
authoritative replacement when ready instead of blocking the initial load.

### Deferred tool history and local cache

Clients opting into `lazyHistory` receive transport projections for replayed tool
outputs over 16 KiB. Inputs, title, status, locations, parent attribution and
lifecycle revisions remain inline; bulky content, raw output and terminal bytes
are replaced by `update._meta.codeaw.deferredTool =
{seq, bytes, hasDiff, exitCode?}`. Collaboration identity/lifecycle reports remain
inline. Ordinary live updates and the durable log are unchanged. Clients that
omit this option still receive full output, including on older bridges.

Authenticated `_codeaw/history/tool` with `{sessionId, epoch, toolCallId}` returns
`{epoch, seq, t, update}` containing the exact folded output from the current log.
Stale epochs and missing tools are rejected. A hydrated tool can be ahead of
pending stream notifications; ignore already-folded updates for that tool through
the returned seq, without advancing the session cursor past unrelated entries.

The app persists complete timeline snapshots and reconnect cursors by paired host.
Native platforms use app-private compressed files; Web uses IndexedDB. It restores
history and the session list before network attachment, then requests delta replay.
Writes are debounced for two seconds and flushed on background/eviction. A host
cache is bounded to 32 snapshots (including the session list) and 128 MiB; older
cache entries may be evicted. Image/file references are retained, but fetching
their bytes and deferred tool output requires the bridge. Forgetting a pairing or
the Settings cache control removes its local cache; bridge history is unaffected.

Desktop turns can start outside codeaw, so state events may refer to native
turn ids. Desktop-origin messages are echoed from the desktop stream rather
than synthesized locally. Closing a linked session unfollows it and cancels
unsent codeaw queue entries; it does not interrupt the desktop turn. Explicit
`session/cancel` interrupts the currently observed native turn. Desktop affinity
is persisted so an unavailable owner fails closed instead of silently falling
back to an independent runtime. Desktop model, effort, permission and collaboration
settings are exposed through the operations described under Prompts. Desktop
deletion remains unavailable.

### `session/list`

Params: standard (`cwd`, `cursor`) plus optional `_meta.codeaw.agentId` filter.
Aggregates every agent's own list with sessions known only to the bridge.
Each `SessionInfo` carries

```jsonc
"_meta": { "codeaw": {
  "agentId": "claude",
  "state": "idle" | "running" | "requires_action",
  "pending": 0,            // open permission/elicitation requests
  "queued": 0,
  "lastSeq": 42,           // 0 when the bridge has no log yet
  "known": true            // bridge has a log for it
}}
```

Agents that failed to list are reported in `_meta.codeaw.errors: [{agentId, message}]`.
`nextCursor` is opaque (it packs every agent's cursor).

### `session/close`, `session/delete`

`close` releases the agent-side session (the bridge keeps the log; the session
can be reopened). `delete` deletes it on the agent (if supported) and removes
the bridge log.

## Event log and replay

Every session has an append-only log. Each entry has a per-session `seq`
(1, 2, 3 …) and is written **before** it is broadcast. Two kinds:

1. Agent updates, sent as standard `session/update`:

   ```jsonc
   { "sessionId": "claude:…", "update": { …SessionUpdate… },
     "_meta": { "codeaw": { "seq": 17, "t": 1790899200000 } } }
   ```

   Message chunks (`user_message_chunk`, `agent_message_chunk`,
   `agent_thought_chunk`) get `update._meta.codeaw.mid`: a message id that
   groups chunks of one message (the agent's `messageId` when present).
   Message identity is scoped by the parent tool-call id as well as type and mid;
   two subagents may reuse the same message id.

2. Bridge events, sent as `_codeaw/event`:

   ```jsonc
   { "sessionId": "claude:…", "event": { "type": "…", … },
     "_meta": { "codeaw": { "seq": 18, "t": 1790899200001 } } }
   ```

| event `type` | fields | meaning |
|---|---|---|
| `state` | `state`, `stopReason?`, `queued`, `turnStartedAt?`, `turnPromptId?`, `completedTurn?` | `running` / `requires_action` / `idle`; active turn fields are omitted when idle; `completedTurn` carries `{ promptId, startedAt, endedAt }` in Unix milliseconds |
| `permission_request` | `requestId`, `toolCall`, `options` | an agent asked for permission |
| `permission_resolved` | `requestId`, `outcome`, `optionName?`, `by?` | answered (by device name) or cancelled |
| `elicitation_request` | `requestId`, `request` | an agent asked for structured input |
| `elicitation_resolved` | `requestId`, `action`, `by?` | |
| `dequeued` | `promptId`, `cancelled?` | a queued prompt started (or was dropped) |
| `error` | `message`, `code?` | turn failed, agent crashed, … |

User prompts are logged as `user_message_chunk` updates with
`_meta.codeaw = { mid, promptId, queued?, steered? }` so every device sees them.

Notification `_meta.codeaw.t` is the log entry's Unix time in milliseconds.

Full replay retains each turn's first active state and completed idle state so clients
can reconstruct per-turn output, elapsed time and action footers. The app labels TPS
with `≈`: it estimates tokens from streamed thought/response text (one per CJK or
full-width character, roughly one per four other characters) and divides by total
turn duration, including tool execution and permission waits. Context usage is not
an output token count. Before any text arrives, the speed is shown as `— TPS`.
Replays preserve it, allowing clients to distinguish current activity from old turns.

Subagent activity uses ordinary ACP tool calls and attributed message chunks.
The bridge advertises `_meta["subagent-transcript"]: true` to receive Claude's
child text/thoughts. The app groups `_meta.claudeCode.parentToolUseId` (or
`_meta.parentToolCallId`) under the delegating Agent/Task card, including nested
delegation. Missing parents remain visible in the main timeline. Child text is
excluded from the main turn's response copy and estimated TPS.

Codex `spawnAgent` and subagent-activity tool reports get delegation cards too.
`rawInput.agentsStates` reports supply child status and results; spawn completion
alone is shown as started, not task completion. During compaction, tool updates
retain `_meta.codeaw.agentStatesSeq`, the seq of their last child-state snapshot,
so later cosmetic updates cannot reorder child status. Tool metadata and parent
attribution survive full/delta replay. Details depend on the adapter's reports;
draft native `subagent_spawned` sessions are not negotiated by this bridge.

The chat's subagent browser lists every delegation, including nested agents. On
phones it opens from the right edge, a leftward swipe across the conversation,
or the app-bar button. Chat areas at least 1000 logical pixels wide use a
collapsible 350-pixel sidebar. Users can filter unfinished agents and open an
agent's activity without scrolling the main conversation.

For Claude, an Agent/Task tool's `completed` status can describe a returned launch
RPC while its child keeps working. Active descendants and later attributed
messages therefore override that status. `run_in_background`, `isAsync` and
`async_launched` identify background launches; structured completion/failure
reports end them. Full replay retains `toolStatusSeq` and `toolLifecycleSeq` in
`update._meta.codeaw` so cosmetic updates cannot move those lifecycle bookends.
The main timeline and subagent browser share the same status calculation.

Image data in logged user messages is replaced by
`{ "type": "image", "mimeType": "…", "data": "", "uri": "codeaw-blob:<sha256>" }`;
fetch the bytes from `/api/blobs/<sha256>`.

`epoch` changes when a log is rebuilt (re-import); a client holding an older
epoch gets a `full` replay.

## Prompts

`session/prompt` is standard. Optional `_meta.codeaw.delivery`:

- `auto` (default): idle → start a turn; running → steer into the running turn
  if the agent supports `_session/steering`, otherwise queue.
- `queue`: always queue behind the running turn.

The response arrives when the turn that handled the prompt ends (a steered
prompt resolves with the running turn). `session/cancel` cancels the running
turn, drops queued prompts (they resolve with `cancelled`) and answers every
open permission/elicitation request with `cancelled`.

Clients may supply a UUID `_meta.codeaw.clientPromptId`. The bridge uses it as
the logged `promptId` and suppresses duplicate delivery within that session,
including replay/reconnect. Older clients receive a bridge-generated UUID.
Acceptance is independent of the turn's eventual RPC response: the bridge logs
the user message and sends a `prompt_receipt` event `{promptId, status}` with
`received` immediately. `read` means confirmed injection/native user echo for
desktop sessions, or first agent response activity for ACP sessions (a successful
non-cancelled completion also confirms read). Queued prompts remain `received`
until consumed. `failed` reports a known dispatch failure; read never regresses.
These receipt events are persisted and replayed, including across a native
history rebuild. They do not indicate response completion or guarantee semantic
understanding. A connection-close exception while awaiting the turn response
does not prove rejection; clients retain the uncertain message and reconcile
with replay instead of restoring the old draft or blindly resending it.

Desktop user echoes carry `promptId`, `receipt: "read"`, `replace: true` and
`partIndex` in `update._meta.codeaw`. The first part replaces the local echo;
later parts append. Steering uses the native item's `clientUserMessageId`
(or its server/restore equivalent), retaining correlation after reattachment.

Codex desktop steering includes the owner's required `restoreMessage` (message
ID, input, cwd, workspace roots and collaboration context), and requires an
accepted result. It never starts a second ACP runtime for a desktop-owned turn.
Desktop `session/set_config_option` supports `model`, `reasoning_effort`, `mode`
(`read-only`, `agent`, `agent-full-access`) and `collaboration_mode` (`default`,
`plan`); `session/set_mode` is also supported. Settings are applied to the next
turn and confirmed from the owner's snapshot. Updated options are returned and
broadcast as `config_option_update`.

## Permission and elicitation requests

The bridge forwards an agent's `session/request_permission` /
`elicitation/create` to **every attached client**, with
`_meta.codeaw.requestId`. The first answer wins; the bridge withdraws the
request from the other clients with `$/cancel_request`. A client attaching
later receives still-open requests right after its replay. Requests never time
out on the bridge.

## Extension methods (client → bridge requests)

| method | params | result |
|---|---|---|
| `_codeaw/agents/list` | – | `{agents: AgentInfo[]}` |
| `_codeaw/agents/restart` | `{agentId}` | `{}` |
| `_codeaw/workspaces/list` | – | `{allowAllPaths, roots: [{path, name, source: "config"\|"session"\|"filesystem"}]}` |
| `_codeaw/fs/list` | `{path}` | `{path, parent?, entries: [{name, path, type: "file"\|"dir"\|"link", size, mtime}]}` |
| `_codeaw/fs/mkdir` | `{path, name}` | `{path, name}` (created child directory) |
| `_codeaw/fs/read` | `{path, maxBytes?}` | `{path, size, mtime, binary, truncated, text?, mimeType?}` |
| `_codeaw/git/status` | `{cwd}` | `{root?, branch?, files: [{path, index, worktree, origPath?}]}` |
| `_codeaw/git/diff` | `{cwd, path?, staged?}` | `{diff, truncated}` |
| `_codeaw/terminal/open` | `{cwd?, terminalId?, afterSeq?, cols?, rows?}` | `{terminalId, cwd, shell, exited, exitCode?, lastSeq, full, events}` |
| `_codeaw/terminal/write` | `{terminalId, data}` | `{}` |
| `_codeaw/terminal/resize` | `{terminalId, cols, rows}` | `{}` |
| `_codeaw/terminal/detach` | `{terminalId}` | `{}` |
| `_codeaw/terminal/close` | `{terminalId}` | `{}` |
| `_codeaw/session/reimport` | `{sessionId}` | `{epoch}` (clients get a `full` replay on next load) |
| `_codeaw/notify/info` | – | `{enabled, server?, topic?}` |
| `_codeaw/notify/test` | – | `{sent}` |
| `_codeaw/cpa/accounts` | `{endpoint, managementKey}` | `{accounts: CpaAccount[], checkedAt}` |
| `_codeaw/cpa/quota` | `{endpoint, managementKey, accountId}` | `CpaQuota` |

File-system methods and `session/new` only accept paths inside the configured
workspaces or a known session `cwd`, unless the PC administrator opts into
`filesystem.allowAllPaths: true`. The opt-in adds existing Windows drive roots
(or `/` on POSIX) and allows all absolute paths accessible to the bridge account.
There is no remote API for enabling it. This exposes private files to every
paired device; it is not a sandbox for agents or interactive shells. Paths are
resolved through links before containment checks, and new sessions require an
existing directory.

`fs/mkdir` resolves and checks the existing parent `path` before creating a
single child. `name` must be a valid single directory component (maximum 200
characters); traversal, separators, control characters and reserved Windows
names are rejected. It never creates missing ancestors or overwrites an
existing file/directory. The result is the canonical created directory path.

### CPA usage (paired clients only)

The bridge calls CLIProxyAPI's management API with a Bearer Management Key,
not a model API key. `endpoint` accepts an HTTP(S) root/prefix, management page,
or explicit `/v0/management` or `/v8/management` URL. Embedded credentials,
query strings and fragments are rejected; redirects are not followed.
Root URLs default to v0. v0 uses `auth-files` and `api-call`; v8 uses
`credentials` and `requests/api-call`. Requests have a 12-second timeout and
an 8 MiB response limit. Connection failures expose no upstream response body.

`CpaAccount` is `{id, name, provider, label, plan, disabled, unavailable,
status, requests, subscriptionUntil}`. `id` is opaque; `requests` is the CPA
success/failure count if supplied, not an allowance. The bridge discards raw
credentials and only caches minimal query metadata for five minutes. Neither
service-provider tokens nor CPA's potentially secret `account` field are
returned to clients. The Management Key is not persisted by the bridge.

`CpaQuota` is `{accountId, windows, resetsRemaining, plan, subscriptionUntil,
checkedAt, status, message?}`, where `status` is `ok`, `error`, `unsupported`,
or `disabled`. Each window is `{id, label, remainingPercent, resetAt,
periodSeconds}`. Percentages mean **remaining**, timestamps are ISO 8601 UTC,
and unknown fields are `null`. Windows are classified from provider durations,
not primary/secondary position. `resetsRemaining` is an actual provider reset
credit count; no reset or redemption action is exposed. Queries use fixed
Codex, Claude, Grok and Antigravity usage/plan URLs via CPA's `$TOKEN$`
substitution; they do not send model prompts or download auth files.

The app persists the endpoint/key in its device secure storage and sends them
over the paired connection. Network access occurs from the PC, so localhost
refers to the bridge machine. Protect remote management connections with
HTTPS or a trusted private network. A past reset timestamp does not prove
replenishment: clients keep the received percentage until refreshed.

The app shares one CPA controller between chat and usage screens. It polls
every 30 seconds in the foreground, refreshes on resume/reconnect and skips
overlapping automatic requests. Each provider/window is averaged independently,
with one vote per account and one decimal display. Unknown, invalid, failed,
disabled and unavailable values are excluded; zero is valid. Main Codex/Claude
weekly/five-hour windows exclude special allowances. AGY first averages groups
of the same duration within each account. The chat header selects the current
agent's provider; missing windows stay unknown rather than borrowing another
provider's value. Quota colors reflect remaining amount: green >=50, amber
20–49.9, red <20, gray unknown.

### File uploads

`POST /api/uploads?sessionId=<qualified-id>&name=<encoded-filename>` accepts raw
bytes with `Content-Type: application/octet-stream` and the same Bearer auth as
ACP. A known session cwd is required. Maximum size is 20 MiB per file; invalid
names, oversized bodies and upload directory links are rejected. Bytes are
saved to a unique filename in `<cwd>/.codeaw-uploads/` without overwriting files.
Success returns HTTP 201 with `{name, path, size, sha256, block}`. `block` is an
ACP `resource_link` with a `file:` URI and local path description; include it in
`session/prompt`. Errors return `{error}` with 400/401/403/413 as appropriate.
Files persist on the PC until explicitly removed.

### Interactive terminals

Terminals are separate from ACP agent sessions. `open` starts an interactive
PowerShell on Windows or the host's `$SHELL` (falling back to `/bin/sh`) on POSIX.
On Windows, writes normalize LF/CRLF to CR so newline means Enter in PSReadLine;
POSIX bytes are unchanged.
The starting `cwd` must be an allowed workspace directory. The shell itself has
the bridge account's usual permissions; the workspace check is not a sandbox.
There is one retained shell per device and starting directory, with at most eight
per device. Only the authenticated device that created a terminal can attach,
write, resize, detach or close it. Dimensions range from 2 to 500; defaults are
80 columns and 24 rows. Input is limited to 64 KiB per request.

Live `_codeaw/terminal/event` notifications contain
`{terminalId, seq, type: "data", data}` or
`{terminalId, seq, type: "exit", exitCode}`. Output is raw terminal text, including
ANSI escape sequences. `open` returns retained events newer than `afterSeq`, plus
`lastSeq`. Notifications can arrive before the open response: buffer them until
the response is applied and discard duplicate sequence numbers. `full: true`
means reset the screen and replay all retained events, because the client is new
or its sequence is outside the retained history.

Leaving the screen detaches without stopping commands. Terminals survive socket
reconnects but expire after ten minutes with no attached viewers, and disappear
when the bridge restarts. About 512 Ki UTF-16 code units of recent output are
retained in memory, with no terminal output written into the agent event log.
`close` ends the shell and releases its slot; a later `open` starts a new shell.
The Node distribution uses prebuilt node-pty bindings; standalone Bun 1.4.2
releases use Bun's built-in PTY support.

## Extension notifications

| direction | method | params |
|---|---|---|
| bridge → client | `_codeaw/activity` | `{sessionId, agentId, state, pending, queued, title?, updatedAt?, turnPromptId?, turnStartedAt?, completedTurn?, work?}` — sent to **all** connections, attached or not |
| bridge → client | `_codeaw/replay` | see `session/load` |
| bridge → client | `_codeaw/event` | see event log |
| bridge → client | `_codeaw/terminal/event` | see interactive terminals |
| client → bridge | `_codeaw/client/state` | `{foreground: bool, activeSessionId?}` |
| client → bridge | `_codeaw/session/detach` | `{sessionId}` — stop pushing this session's updates/requests to this connection |

## Push notifications

### Live Activity extensions

`work` is `{project, phase, summary, updatedAt}`. `phase` is `thinking`,
`command`, `tool`, `responding`, `attention`, `completed`, `cancelled`, `error`
or `disconnected` (keeps the turn identity while its desktop owner is offline;
it is not treated as completion).
`summary` is a bounded plain-text excerpt (180 Unicode code points) of a command
or a summary/progress message already supplied by the agent. `project` is the
working-directory name. Work changes are coalesced for 500 ms for socket clients.
Turn/completion timestamps are Unix milliseconds and retain their existing
protocol meanings. Old native turns and nested subagent text do not replace
the current parent-turn activity.

Authenticated requests:

| Method | Params | Result |
| --- | --- | --- |
| `_codeaw/activity/list` | `{}` | `{activities: [...]}` current work/turn snapshots without attaching to chat replay |
| `_codeaw/live_activity/info` | `{}` | `{enabled, ready, environment?, includeDetails?, error?}` no key or token |
| `_codeaw/live_activity/register` | `{activityId, sessionId, turnId, pushToken, includeDetails?}` | `{registered, ...info}`; binds to the authenticated device, accepts only its current/completed turn |
| `_codeaw/live_activity/unregister` | `{activityId}` | `{}`; can remove only the requesting device's registration |

The bridge's optional `notifications.liveActivity` configuration holds APNs
team/key/bundle/environment values and a **PC-local** private-key path. It sends
HTTP/2 ActivityKit updates with the app bundle's `.push-type.liveactivity` topic.
Content state fields are `{title?, backgroundUpdates?, project, agent, state, phase, summary, startedAt,
endedAt?, updatedAt}`, with Unix **milliseconds** for its three time fields.
Only APNs `timestamp`, `stale-date` and `dismissal-date` are Unix seconds.
Details require consent in both PC config and phone settings. Push updates are
coalesced for 15 seconds, use 120-second stale dates and 60-second heartbeats;
end events retain the final display for 60 seconds. Registrations survive socket
disconnects but are in memory and must be renewed after bridge restart.
See [iOS Live Activities](live-activities.md) for signing/device prerequisites.
`title` is the chat title (falling back to project). Both are redacted when details
are hidden. `backgroundUpdates` is true on APNs payloads and on local updates only
after that activity's token was registered successfully. The app tracks all running
snapshots and requests multiple activities; ActivityKit controls the device limit.
Registrations are limited to 16 per paired device and 64 across the bridge.

### ntfy

When an event needs attention (permission/elicitation request, turn finished,
error) and **no client is connected at all**, the bridge waits
`notifications.ntfy.delaySeconds` and, if still unanswered and still nobody is
connected, publishes to ntfy with `click = codeaw://session/<sessionId>`.
Message text contains only the agent name and the kind of event unless
`includeDetails: true`.
