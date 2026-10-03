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

Params: standard plus optional `_meta.codeaw.afterSeq` and `_meta.codeaw.epoch`.

1. The bridge first sends `_codeaw/replay` `{sessionId, mode: "full"|"delta", epoch}`.
   - `delta` when the client passed `afterSeq` and the same `epoch`: only log
     entries with `seq > afterSeq` follow, unmodified.
   - `full` otherwise: the client must clear its timeline; a **compacted**
     history follows (message chunks merged, tool calls folded into their final
     state, terminal output concatenated, snapshot-type updates reduced to the
     last one).
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

Desktop turns can start outside codeaw, so state events may refer to native
turn ids. Desktop-origin messages are echoed from the desktop stream rather
than synthesized locally. Closing a linked session unfollows it and cancels
unsent codeaw queue entries; it does not interrupt the desktop turn. Explicit
`session/cancel` interrupts the currently observed native turn. Desktop affinity
is persisted so an unavailable owner fails closed instead of silently falling
back to an independent runtime. Desktop settings and deletion are not exposed
through this first integration.

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
| `_codeaw/workspaces/list` | – | `{roots: [{path, name, source: "config"\|"session"}]}` |
| `_codeaw/fs/list` | `{path}` | `{path, parent?, entries: [{name, path, type: "file"\|"dir"\|"link", size, mtime}]}` |
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

File-system methods only accept paths inside the configured workspaces or a
known session `cwd`.

### Interactive terminals

Terminals are separate from ACP agent sessions. `open` starts an interactive
PowerShell on Windows or the host's `$SHELL` (falling back to `/bin/sh`) on POSIX.
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
| bridge → client | `_codeaw/activity` | `{sessionId, agentId, state, pending, queued, title?, updatedAt?}` — sent to **all** connections, attached or not |
| bridge → client | `_codeaw/replay` | see `session/load` |
| bridge → client | `_codeaw/event` | see event log |
| bridge → client | `_codeaw/terminal/event` | see interactive terminals |
| client → bridge | `_codeaw/client/state` | `{foreground: bool, activeSessionId?}` |
| client → bridge | `_codeaw/session/detach` | `{sessionId}` — stop pushing this session's updates/requests to this connection |

## Push notifications

When an event needs attention (permission/elicitation request, turn finished,
error) and **no client is connected at all**, the bridge waits
`notifications.ntfy.delaySeconds` and, if still unanswered and still nobody is
connected, publishes to ntfy with `click = codeaw://session/<sessionId>`.
Message text contains only the agent name and the kind of event unless
`includeDetails: true`.
