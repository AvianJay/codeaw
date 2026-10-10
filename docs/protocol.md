# codeaw bridge protocol

The bridge is an **ACP v1 agent over WebSocket** (the WebSocket profile of the
ACP "Streamable HTTP & WebSocket Transport" RFD) that fronts local ACP stdio
agents and the native Antigravity CLI NDJSON adapter. Every client message is plain ACP v1
JSON-RPC; everything codeaw adds lives in ACP extension points:

- `_meta.codeaw` objects on standard requests, responses and notifications
- extension methods / notifications whose names start with `_codeaw/`

A generic ACP client can use the bridge as a normal agent. The codeaw app uses
the extensions for durability (replay after reconnect), multi-device sync and
the extra screens (files, git, pairing).

## Transport and auth

Remote desktop is a separate authenticated REST/WebSocket transport, available
even when the user's ACP bridge is offline at Windows sign-in. See
[remote desktop setup](remote-desktop.md).

| Endpoint | Desktop operation |
|---|---|
| `GET /api/desktop/info` | Version, local opt-in, availability, monitors, modes and privilege capabilities |
| `POST /api/desktop/sessions` | `{mode?, monitorId?, privilege?, fps?}` → `{sessionId, ticket, socketPath}` |
| `WS /api/desktop/sessions/:id/socket` | First text message `{type:"auth", ticket}`; ticket expires after 30 seconds and is single-use |
| `DELETE /api/desktop/sessions/:id` | End the authenticated device's own session |

REST uses Bearer device authentication; desktop WebSocket URLs contain no tokens.
An unverified socket closes after three seconds. Only one desktop control session
can exist; reservation expires if its ticket is not used. Device revocation also
ends active desktop sockets and their WebRTC peers.

Modes are `balanced`, `smooth`, `low`, `onDemand`; privileges are `user`, `system`.
`system` is available only after local installation of the advanced service.
FPS selection is 30 or 60 for `smooth`. Configure messages update mode, FPS or
monitor, while privilege changes require a new session.

JPEG frame messages are binary: a four-byte little-endian JSON-header length,
UTF-8 metadata, then tile bytes. Metadata contains `type:"frame"`, `epoch`, `seq`,
`width`, `height`, `sourceWidth`, `sourceHeight`, `full`, and
`tiles:[{x,y,width,height,offset,length}]`. Tile offsets are relative to the payload.
The client applies the whole frame before replying `{type:"ack",epoch,seq}`.
There is at most one unacknowledged frame. New screen generations start with a
full frame; old frames and input generations are discarded.

Text messages include `configure` with `options`, `refresh`, and
`input` with `epoch` and `input:{kind,...}`. Kinds are pointer, button, wheel, key,
text, release and sas. Pointer coordinates are normalized within the selected
physical monitor. Text is committed Unicode; special keys use Windows virtual-key
codes and explicit down/up. Release also works while input is paused.

The server sends `status`, `info`, `notice`, `error`, and `cursor`; cursor shape
changes include a bounded PNG and scaled hotspot. H.264 uses WebRTC media, with
`offer`/`answer` and `candidate` signaling on the desktop socket. Signaling and
video status carry `epoch`. Receiver stats adjust encoding bitrate; NACK and PLI
feedback support recovery. Failure falls back to JPEG balanced mode.

Desktop image data does not use ACP gzip framing or WebSocket deflate and is not
written to session history. Leaving the screen/backgrounding ends capture and
releases worker-owned input. The advanced gateway serves the same public origin
and verifies the private backend pipe's owner SID before forwarding credentials;
it imports no agent runtime.

| Endpoint | Purpose | Auth |
|---|---|---|
| `GET /acp` (WebSocket upgrade) | ACP JSON-RPC, one text frame per message | `Authorization: Bearer <deviceToken>` (browsers may use `?token=`) |
| `POST /api/pair` | exchange a one-time pairing code for a device token | pairing code in body |
| `GET /api/health` | liveness, version | none |
| `GET /api/device` | validate the saved device token; returns `deviceId` | Bearer |
| `GET /api/blobs/<sha256>` | image bytes referenced from the event log | Bearer |
| `GET /api/fs/raw?path=<abs path>` | raw file bytes (image preview) | Bearer |
| `GET /api/fs/raw?path=<abs path>&download=1` | original file bytes with an attachment filename, no preview/upload size cap | Bearer |
| `POST /api/fs/archive` | stream a ZIP of selected files/folders, `{path: <base directory>, paths: [<absolute paths>]}` | Bearer |
| `POST /api/uploads?sessionId=<id>&name=<filename>` | upload session attachment bytes, at most 512 MiB; HTTP 201 | Bearer |
| `POST /api/uploads?name=<filename>` | upload bridge-scoped attachment bytes, at most 512 MiB; HTTP 200 | Bearer |

The server pings every 20 s and drops sockets that miss two pongs. Clients
should also ping and reconnect with exponential backoff.

WebSocket compression is described under the local cache below. Web app assets
carry a weak `ETag` and answer `If-None-Match` with 304. Text, JSON and wasm
assets of at least 1 KiB are gzipped for clients that send
`Accept-Encoding: gzip`.

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

For `transport: agy`, the suffix is a stable bridge UUID. The adapter stores its
mapping to AGY's `conversation_id` under `data/agy/<agentId>/`; every subsequent
process uses `--conversation` with that native ID. Each session has its own
NDJSON subprocess, settings and working directory. Bridge history supplies replay.
`step_update` response deltas map to ACP message chunks; tool steps map to tool
calls/updates; `result.usage` maps to cumulative ACP usage in the prompt response.

AGY advertises text/embedded context and resume/close, with `steering: false`.
Inline images, interactive permissions and elicitation are unsupported by its
headless protocol. File resource links remain explicit text references; other
non-text content is rejected before invoking the CLI. Mid-turn prompts queue.
Model, mode and supported effort changes apply to the next turn by restarting
only that session with its native ID. Cancel terminates only its process tree.
Permission policy is inherited from local AGY settings; no approval bypass is added.

## initialize

The response is a normal `InitializeResponse` with

```jsonc
"_meta": { "codeaw": {
  "version": 1,
  "host": "my-pc",
  "projectless": true,                // supports managed no-project conversations
  "editPrompts": true,                // supports _codeaw/session/fork (editing sent messages)
  "fileArchives": true,               // supports authenticated POST /api/fs/archive
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
  "steering": true,                      // agent supports mid-turn steering
  "forkAtMessage": true                  // session/fork honours a fork point (once started)
}
```

## Session lifecycle

### `session/new`

Params: standard (`cwd`, `mcpServers` — the bridge always sends `[]` to the
agent) plus

```jsonc
"_meta": { "codeaw": {
  "agentId": "claude",                       // required unless only one agent is configured
  "projectless": true,                        // optional: no selected project; cwd may be ""
  "initialConfig": { "mode": "default" }     // optional: set_config_option calls applied right after creation
}}
```

Response: the agent's `NewSessionResponse` with `sessionId` rewritten and
`models` removed, plus `_meta.codeaw = { agentId, lastSeq, epoch, cwd, projectless }`.

When `projectless: true`, the bridge ignores the supplied `cwd` and
`additionalDirectories`, creates a unique persistent `<dataDir>/chats/<uuid>/`
directory, and uses it as the agent's cwd. Attachments remain under that chat's
`.codeaw-uploads/`. It works with no configured workspaces and without enabling
`filesystem.allowAllPaths`. Each chat gets a distinct folder; normal project
creation still requires an existing allowed directory. New/load/resume/list
responses retain `_meta.codeaw.projectless`, and activity notifications carry
`projectless` with `work.project: "無專案"`. Clients should display this label
instead of the generated folder name and omit these folders from recent project
suggestions. Check `initialize._meta.codeaw.projectless` before offering creation
against an older bridge. Failed creation removes only an empty allocated folder;
deleting session history preserves working files. This is not an agent sandbox.

### `session/load` (attach + replay)

Params: standard plus optional `_meta.codeaw.afterSeq`, `_meta.codeaw.epoch`,
`_meta.codeaw.lazyHistory: true`, `_meta.codeaw.lazyHistoryBytes` and
`_meta.codeaw.pageBytes` (see [Paged history](#paged-history)).

1. The bridge first sends `_codeaw/replay` `{sessionId, mode: "full"|"delta", epoch, before?}`.
   - `delta` when the client passed `afterSeq` and the same `epoch`: only log
     entries with `seq > afterSeq` follow in log order, with the negotiated
     deferred-output projection when `lazyHistory` is enabled. A paging client
     whose delta would exceed two pages gets a paged `full` replay instead,
     because deltas carry uncompacted streaming chunks.
   - `full` otherwise: the client stages a replacement timeline; a **compacted**
     history follows (message chunks merged, tool calls folded into their final
     state, terminal output concatenated, snapshot-type updates reduced to the
     last one). With `pageBytes`, only the newest page follows and `before` is set
     when older history remains.
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

For a previously desktop-linked conversation, load/resume replays the bridge's
saved history even when the desktop pipe or owner is unavailable after reboot.
It returns `connection: "desktop", desktopConnected: false` without starting
ACP, registering the conversation for automatic owner discovery. When the owner
becomes available, an authoritative full replay replaces the saved history and
state events report `desktopConnected: true`, without another client load.
The owner must have that conversation open in Codex desktop; no alternate owner
is created. Prompts and settings require a connected owner and are rejected
before acceptance while disconnected. The app keeps the draft and disables send.
Recovery never overwrites current desktop settings with cached bridge settings
or automatically resends prompts whose delivery is uncertain.

The desktop's snapshot and revisioned patches are authoritative. A historical
edit or newly loaded older history can trigger a new epoch and a live full
replay. Such a replay ends with `_codeaw/replay` `{mode: "complete", epoch,
lastSeq, before?}`; clients clear their replay flag and advance the cursor at this
boundary without waiting for a load response. Paging clients receive only the
newest page, and `before` is the page cursor. Duplicate/replayed text is not
appended twice.

Desktop attach returns the owner's current snapshot immediately. If older turns
are incomplete, the bridge requests them in the background and delivers the
authoritative replacement when ready instead of blocking the initial load.

### Deferred tool history and local cache

Clients opting into `lazyHistory` receive transport projections for replayed tool
updates over 4 KiB, or over `lazyHistoryBytes` (512 B–4 KiB) when given; the
app's data saver uses 2 KiB. Small inputs (at most 1 KiB), bounded titles (256 characters),
status, locations, parent attribution and lifecycle revisions remain inline;
bulky inputs, content, raw output, duplicated Claude tool responses and terminal bytes
are replaced by `update._meta.codeaw.deferredTool =
{seq, bytes, hasDiff, exitCode?}`. Collaboration identity/lifecycle reports remain
inline. Ordinary live updates and the durable log are unchanged. Clients that
omit this option still receive full output, including on older bridges.

Authenticated `_codeaw/history/tool` with `{sessionId, epoch, toolCallId}` returns
`{epoch, seq, t, update}` containing the exact folded output from the current log.
Expansion also restores the original full title and input. Deferred historical
diffs stay folded until explicitly opened so merely scrolling through a long
chat cannot download every patch. Stale epochs and missing tools are rejected.
A hydrated tool can be ahead of
pending stream notifications; ignore already-folded updates for that tool through
the returned seq, without advancing the session cursor past unrelated entries.

### Paged history

`pageBytes` (8 KiB–8 MiB of transport JSON) makes full replays newest-first.
The bridge sends the most recent compacted groups that fit, starting at a prompt
unless the current turn is over four pages. Session snapshots (`plan`, commands,
mode, config, usage, `session_info_update`) always come first, wherever they
appeared. When the page starts inside an active turn, that turn's latest
`running`/`requires_action` state comes first too. `before` is the oldest sent
group's first-appearance seq; it is stable for the epoch.

Authenticated `_codeaw/history/page` with `{sessionId, epoch, before,
pageBytes?}` responds `{}` after sending one notification to the requester. The
session must be attached:

```jsonc
// _codeaw/history/page
{ "sessionId": "claude:…", "epoch": "…", "requested": 812, "before": 403,
  "entries": [ { "seq": 403, "t": 1790899200000, "update": { … } },
               { "seq": 410, "t": 1790899200300, "event": { "type": "state", … } } ] }
```

Entries are the compacted groups that first appeared before `requested`, newest
page, in log order, with the negotiated tool projection. `before` is absent at
the beginning of the conversation. The notification is queued with live updates,
so it reflects every update the client received before it. Reduce the page
separately and place it before the loaded history. A page copy of an already
loaded item, such as a tool that kept running, replaces the partial live copy.
A request that also appears in newer history keeps its resolution. A turn split
across pages is joined. Stale epochs and unattached clients are rejected. Clients
that omit `pageBytes`, and older bridges, receive whole replays without `before`.

The app persists complete timeline snapshots and reconnect cursors by paired host.
Native platforms use app-private compressed files; Web uses IndexedDB. It restores
history and the session list before network attachment, then requests delta replay.
The page cursor is cached with the snapshot. Scrolling near the top loads the
previous page (192 KiB, or 48 KiB with data saver, which also loads images on tap).
Read receipts and queue results whose prompt lies in an unloaded page are also
cached, then applied when that older prompt is loaded after an App restart.
Writes are debounced for two seconds and flushed on background/eviction. A host
cache is bounded to 32 snapshots (including the session list) and 128 MiB; older
cache entries may be evicted. Image/file references are retained, but fetching
their bytes and deferred tool output requires the bridge. Forgetting a pairing or
the Settings cache control removes its local cache; bridge history is unaffected.

On runtimes that support it, the WebSocket server negotiates `permessage-deflate`
with native and browser clients. Context takeover is disabled in both directions, compression concurrency
is bounded, and messages smaller than 1 KiB stay uncompressed. Clients that do not
offer compression continue to work. Compression does not change sequence numbers,
the JSON protocol or durable history, and images/files use separate HTTP requests.

Codeaw App also opts into `?codeawCompression=gzip` on `/acp`. The bridge sends
JSON messages of at least 1 KiB as binary gzip frames when this reduces their
size; smaller/incompressible messages stay text. App clients decode either form
before JSON-RPC handling. This works in packaged Bun runtimes whose `ws` server
shim does not implement permessage-deflate. Without the query, clients retain
ordinary ACP text frames. Older bridges ignore the query and still send text.
Gzip frames disable additional WebSocket compression to avoid double compression.

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
can be reopened). `delete` removes the bridge log and persists a deletion marker,
so retained agent histories cannot reappear through listing or loading after
reconnect/restart. For ordinary sessions it also attempts agent-side deletion
when supported. Desktop-linked sessions are only detached and removed from
Codeaw; the desktop conversation remains. Project directories and uploads are
preserved. Busy sessions (running turns, pending requests or queued messages)
reject deletion rather than cancelling work. Successful deletion broadcasts
`_codeaw/activity {sessionId, agentId, deleted: true}` to paired clients, which
remove the session list entry and persisted timeline/cache. Repeated deletion
is idempotent. The App requires explicit confirmation before sending it.

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
| `dequeued` | `promptId`, `cancelled?`, `removed?` | a queued prompt started (or was dropped); `removed: true` hides a withdrawn unsent message |
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

The bridge also advertises `clientCapabilities.subagents: {}`. Native ACP
`subagent_update` reports and Codex's earlier `subagent_spawned` /
`subagent_state_update` reports are translated before stable SDK validation into
one delegation tool per child thread. Child messages and scoped tool IDs are
attributed to that tool in the root conversation, including nested delegation.
Child permission and input requests reach the root conversation with their
original RPC IDs; child settings and quota snapshots do not replace the root's.
Resumed Codex generations reuse the card and ignore late previous-generation
events. Native associations are cleared when loading or closing a root session.

Legacy Codex activity reports are grouped by `rawInput.agentThreadId`, so an
interaction does not create another agent or imply task completion. Actual
start/completion/interruption reports and `rawInput.agentsStates` supply status;
completion of a launch or interaction RPC alone does not finish its child.
Compaction retains `_meta.codeaw.agentStatesSeq`, the revision of the actual
child-state report, so later cosmetic updates cannot reorder lifecycle state.
Tool metadata and parent attribution survive full/delta replay.

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

The app sends `@` file mentions in place as `resource_link` blocks
(`name` is the path relative to the session folder, `uri` a `file:` URI), so a
prompt can be `text, resource_link, text`.

The response arrives when the turn that handled the prompt ends (a steered
prompt resolves with the running turn). `session/cancel` cancels the running
turn, drops queued prompts (they resolve with `cancelled`) and answers every
open permission/elicitation request with `cancelled`.

`_codeaw/session/remove_prompt` is a request with `{sessionId, promptId}` (a UUID).
It returns `{removed: true}` after withdrawing only that queued/uncertain prompt;
it does not stop the active turn, settle permission requests or clear other prompts.
The bridge broadcasts and persists `dequeued` with `cancelled: true, removed: true`.
An unknown UUID also gets a tombstone, preventing a late request from sending it.
Already dispatched/read prompts return `{removed: false, reason: "processing"}`.
No desktop owner or agent process is needed to withdraw a pending prompt. Repeated
removal is safe, including after reconnect and a desktop history rebuild.
Queued requests resolve with `stopReason: "cancelled"`. On bridge restart, old
unsent queue entries are marked cancelled and are never automatically resent.

### Editing a sent message

`_codeaw/session/fork` with `{sessionId, messageId, prompt, clientPromptId, replace?}`
branches a chat just before one of its main-thread user messages and starts a turn
with `prompt` there. `messageId` is the message's `update._meta.codeaw.mid`
(`u-<promptId>` for prompts sent through codeaw). The response is the new chat's
`session/new`-style setup (`sessionId`, `configOptions`, `modes`,
`_meta.codeaw`) plus `replaced` when `replace` was requested. It arrives after the
turn has been accepted, not when it ends; load the new session to follow it.

- The branch keeps every turn before the edited prompt's turn. Its fork point is the
  last main-thread `agent_message_chunk`/`agent_thought_chunk` `messageId` before
  that turn (subagent messages do not count). The bridge calls the agent's
  `session/fork` with `_meta.jetbrains.air.fork = {version: 1, messageId}`. That
  fork point is honoured by claude-agent-acp 0.71.0+ and codex-acp 1.8.0+, which
  `AgentInfo.forkAtMessage` reports once the agent has started. Other agents,
  including older adapters that would copy the whole conversation, are refused.
- Editing the first prompt needs no fork point: any agent gets a fresh
  `session/new` in the same working directory.
- Turns between the fork point and the edited prompt without any agent message id
  (e.g. cancelled before output) are left out, both by the agent and in the copied
  history. If earlier turns exist but none reported a message id, the edit is refused.
- The new chat starts with the original log up to the fork point (renumbered, a new
  epoch). Prompts that had not started by then are dropped. Model, effort, mode and
  other select/boolean settings of the original chat are applied to the branch.
- Refused: desktop-linked chats, busy chats (running turn, open requests or
  queue), prompts inserted into a running turn (steered), and prompts that never
  started. Files changed on the computer are never restored.
- `replace: true` then removes the original chat from Codeaw like `session/delete`
  (deletion marker and `_codeaw/activity {deleted: true}`), but keeps the agent's
  own history. If the original became busy meanwhile it is kept and `replaced` is
  false.
- The same `clientPromptId` (a UUID, used as the new prompt's `promptId`) returns the
  branch created first, so a retry after a dropped connection never branches twice.
- `{sessionId, messageId, dryRun: true}` performs every check (starting the agent if
  needed) without branching and returns `{ok: true, newSession}`; clients call it
  before letting the user edit.

Prompts may reuse an image already stored by the bridge as
`{type: "image", data: "", uri: "codeaw-blob:<sha256>"}`; the bridge fills in the
bytes before sending the prompt to the agent. An edited message can therefore keep
its images without downloading them.

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

Windows Codex desktop async `agentMessage` items with `delivery: "async"` and
structured `questions` are exposed through the same durable `elicitation/create`
flow. `_meta.codeaw.async: true` marks input that does not pause an active turn.
Each question property has its native serialized question-item id as the key;
`requestedSchema.properties[key]._meta.codeaw.allowCustom: true` enables a free
text answer alongside `enum` / `oneOf` suggestions. The form returns one string
per question, using the same property for a choice or custom answer. Defaults
only preselect a choice; clients must await explicit submission.

The bridge sends the native `send_user_message_question_reply` envelope to the
desktop owner, steering the active turn or continuing the same idle conversation.
It detects previously answered question ids in canonical/live native history;
partial replies leave only unanswered fields pending. Only questions from the
latest turn remain actionable, including after it completes. A newer turn
withdraws earlier forms; interrupted, cancelled and failed turns do not restore
questions. Historical question text remains in the transcript. A timeout never
causes a duplicate turn. Ordinary Markdown bullet lists do not become questions.

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
| `_codeaw/fs/search` | `{cwd, query?, limit?}` | `{cwd, files: [{path, relative, type: "file"\|"dir"}], truncated}` — best matches first; `relative` uses `/` |
| `_codeaw/git/status` | `{cwd}` | `{root?, branch?, files: [{path, index, worktree, origPath?}]}` |
| `_codeaw/git/diff` | `{cwd, path?, staged?}` | `{diff, truncated}` |
| `_codeaw/terminal/open` | `{cwd?, terminalId?, afterSeq?, cols?, rows?}` | `{terminalId, cwd, shell, exited, exitCode?, lastSeq, full, events}` |
| `_codeaw/terminal/write` | `{terminalId, data}` | `{}` |
| `_codeaw/terminal/resize` | `{terminalId, cols, rows}` | `{}` |
| `_codeaw/terminal/detach` | `{terminalId}` | `{}` |
| `_codeaw/terminal/close` | `{terminalId}` | `{}` |
| `_codeaw/session/reimport` | `{sessionId}` | `{epoch}` (clients get a `full` replay on next load) |
| `_codeaw/session/remove_prompt` | `{sessionId, promptId}` | `{removed, reason?: "processing"}` |
| `_codeaw/session/fork` | `{sessionId, messageId, prompt, clientPromptId, replace?}` or `{sessionId, messageId, dryRun: true}` | new chat setup + `replaced?`, or `{ok, newSession}` (see editing a sent message) |
| `_codeaw/history/tool` | `{sessionId, epoch, toolCallId}` | `{epoch, seq, t, update}` (see deferred tool history) |
| `_codeaw/history/page` | `{sessionId, epoch, before, pageBytes?}` | `{}` after the `_codeaw/history/page` notification (see paged history) |
| `_codeaw/notify/info` | – | `{enabled, server?, topic?}` |
| `_codeaw/notify/test` | – | `{sent}` |
| `_codeaw/cpa/accounts` | `{endpoint, managementKey}` | `{accounts: CpaAccount[], checkedAt}` |
| `_codeaw/cpa/quota` | `{endpoint, managementKey, accountId}` | `CpaQuota` |

File-system methods and project-based `session/new` only accept paths inside the configured
workspaces or a known session `cwd`, unless the PC administrator opts into
`filesystem.allowAllPaths: true`. The opt-in adds existing Windows drive roots
(or `/` on POSIX) and allows all absolute paths accessible to the bridge account.
There is no remote API for enabling it. This exposes private files to every
paired device; it is not a sandbox for agents or interactive shells. Paths are
resolved through links before containment checks, and new sessions require an
existing directory.

`fs/search` ranks git's tracked and unignored files (and their folders) when
`cwd` is in a repository; elsewhere it walks the folder, skipping dependency
and build folders, within size and time limits. File lists are cached for ten
seconds.

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
credentials and only caches minimal query metadata and normalized quotas in
bounded, endpoint/key-isolated memory scopes (evicted after 30 idle minutes). Neither
service-provider tokens nor CPA's potentially secret `account` field are
returned to clients. The Management Key is not persisted by the bridge.

`CpaQuota` is `{accountId, windows, resetsRemaining, plan, subscriptionUntil,
checkedAt, status, message?, retryAt?}`, where `status` is `ok`, `stale`, `error`, `unsupported`,
or `disabled`. Each window is `{id, label, remainingPercent, resetAt,
periodSeconds}`. Percentages mean **remaining**, timestamps are ISO 8601 UTC,
and unknown fields are `null`. Windows are classified from provider durations,
not primary/secondary position. `resetsRemaining` is an actual provider reset
credit count; no reset or redemption action is exposed. Queries use fixed
Codex, Claude, Grok and Antigravity usage/plan URLs via CPA's `$TOKEN$`
substitution; they do not send model prompts or download auth files.

Concurrent account-list and per-account quota requests are shared across devices.
Lists and ordinary quota results are cached for 30 seconds; successful Claude
quotas for five minutes, with at least one second between account starts. Claude
profile queries occur at most hourly and only after successful usage queries.
Both management HTTP 429 and embedded provider 429 honor seconds/HTTP-date
`Retry-After`; otherwise retries back off from one minute up to fifteen minutes.
A provider cooldown covers the same provider within that endpoint/key scope,
including manual refreshes; a management API 429 cools down the whole scope.
During cooldown, a previous successful result has `status: stale`,
its original `checkedAt` and a `retryAt`; without a prior result it stays `error`
with no percentages. Stale averages are marked `*`, with times in account details.

The app persists the endpoint/key in its device secure storage and sends them
over the paired connection. Network access occurs from the PC, so localhost
refers to the bridge machine. Protect remote management connections with
HTTPS or a trusted private network. A past reset timestamp does not prove
replenishment: clients keep the received percentage until refreshed.

The app shares one CPA controller between chat and usage screens. It polls
every 30 seconds in the foreground, refreshes on resume/reconnect and skips
overlapping automatic requests. Each provider/window is averaged independently,
with one vote per account and one decimal display. Marked stale values retain
their previous weight while rate-limited. Unknown, invalid, failed,
disabled and unavailable values are excluded; zero is valid. Main Codex/Claude
weekly/five-hour windows exclude special allowances. AGY first averages groups
of the same duration within each account. The chat header selects the current
agent's provider; missing windows are hidden, never borrowed from another
provider. Quota colors reflect remaining amount: green >=50, amber
20–49.9, red <20. Account details still show unsupported or unknown quotas.

### File downloads and ZIP exports

`GET /api/fs/raw?path=<absolute-path>&download=1` returns the complete file as an
attachment with its MIME type, byte length and RFC 5987 Unicode filename.
It uses `Cache-Control: no-store` so downloads reflect current PC contents.
Single files have no preview/upload size cap. Authentication and `resolveReadable`
workspace/session/upload-root checks are unchanged.

When `initialize._meta.codeaw.fileArchives` is true, authenticated
`POST /api/fs/archive` accepts JSON `{path: <allowed base directory>,
paths: [<absolute selected files/folders>]}`. The body is limited to 64 KiB,
with 1–500 selections, at most 10,000 archive entries and 2 GiB of file content.
Every selection must be below the base directory and pass the readable path guard.
The full manifest is validated before sending headers; invalid selections return
JSON with HTTP 400/403/404/413 rather than a partial archive.

The response is an `application/zip` attachment, using ZIP STORE to keep its
final `Content-Length` known and avoid compression load during live AI turns.
UTF-8 names, relative directory structure and empty folders are retained;
overlapping selections are deduplicated. Folder traversal skips symlinks and
Windows junctions. Each file is rechecked and opened lazily, one at a time;
backpressure bounds memory. Cancelling the HTTP response closes the active file.
Changes to file sizes or read errors during transfer terminate the response;
clients must reject incomplete downloads, never export their partial files.

Native clients stream into a unique local temporary directory. On completion
they hand the local file to the OS save picker or share sheet and clean it up
afterwards; sharing never includes a PC path or device token. Web clients keep
the response in a browser Blob rather than copying it into Dart byte arrays.
They download via a Blob URL or invoke Web Share from a fresh user gesture.
Browser requests add `inline=1` to either export route to omit the attachment
header while preserving `no-store` and the exact length. This avoids automatic
attachment handling interrupting large XHR Blob transfers; the save click later
supplies the filename through the local Blob URL's `download` attribute.
Progress uses received bytes and `Content-Length`, and cancellation/failure
removes the local partial file or Blob. A 100% progress event alone does not
mean the file is ready; the full HTTP response must complete first.

### File uploads

`POST /api/uploads?sessionId=<qualified-id>&name=<encoded-filename>` accepts raw
bytes with `Content-Type: application/octet-stream` and the same Bearer auth as
ACP. A known session cwd is required. Maximum size is 512 MiB per file; invalid
names, oversized bodies and upload directory links are rejected. Bytes are
saved to a unique filename in `<cwd>/.codeaw-uploads/` without overwriting files.
Success returns HTTP 201 with `{name, path, size, sha256, block}`. `block` is an
ACP `resource_link` with a `file:` URI and local path description; include it in
`session/prompt`. Errors return `{error}` with 400/401/403/413 as appropriate.
Files persist on the PC until explicitly removed.

The bridge writes and hashes bounded chunks directly to disk and removes its
new file if transfer/write fails. Native pickers stream the source file; Web
pickers submit their browser Blob without creating a whole-file Dart byte copy.
The request deadline is one hour, with a two-minute idle timeout on the bridge.

Clients can report bytes handed to the upload transport while the request is
in flight. Reaching 100% is not a storage acknowledgement: only the HTTP 201
response confirms success. Until then, clients keep the upload pending and do
not attach its resource or send a prompt referencing it. Native clients flush
bounded chunks with transport backpressure; Web clients use XMLHttpRequest
upload progress events. Both allow up to one hour for an active transfer.

For compatibility with clients that omit `sessionId`, the same endpoint returns
HTTP 200 `{path, uri, name, size, mimeType?}` and saves under
`<dataDir>/uploads/<id>/<name>`. These files have 30-day retention and are readable
through authenticated `fs/read` and `fs/raw`, but are not offered as workspaces.
Both variants share the 512 MiB cap, streaming writes and transfer deadlines.
Supplying an invalid/unknown `sessionId` is an error and never falls back to the
bridge-scoped route. Storage errors remove partial files and return HTTP 500.

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
| bridge → client | `_codeaw/history/page` | see paged history; only to the requesting connection |
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

The iOS app may add optional `locationUpdates` to local content state to label
its explicitly enabled background location session. This is independent of
`backgroundUpdates`/APNs registration; no coordinates are added to this protocol.
All active local content uses a stale date 120 seconds after the latest received
bridge snapshot, including when APNs is unavailable. Stale content retains its
system timer and shows “更新已暫停”. Optional native restoration runs after the
app's first screen and cannot block loading saved chats.

### ntfy

When an event needs attention (permission/elicitation request, turn finished,
error) and **no client is connected at all**, the bridge waits
`notifications.ntfy.delaySeconds` and, if still unanswered and still nobody is
connected, publishes to ntfy with `click = codeaw://session/<sessionId>`.
Message text contains only the agent name and the kind of event unless
`includeDetails: true`.
