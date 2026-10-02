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
   `{ modes?, configOptions?, _meta: { codeaw: { agentId, lastSeq, epoch, state, queued } } }`.
4. Pending permission / elicitation requests are then (re)sent to this client.

From then on the connection is **attached**: every new log entry is pushed to it.

If the bridge has no log for the session (it was created outside codeaw, e.g.
in a terminal), it imports it first through the agent's own `session/load`.

`session/resume` attaches without any replay and returns the same response.

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
     "_meta": { "codeaw": { "seq": 17 } } }
   ```

   Message chunks (`user_message_chunk`, `agent_message_chunk`,
   `agent_thought_chunk`) get `update._meta.codeaw.mid`: a message id that
   groups chunks of one message (the agent's `messageId` when present).

2. Bridge events, sent as `_codeaw/event`:

   ```jsonc
   { "sessionId": "claude:…", "event": { "type": "…", … },
     "_meta": { "codeaw": { "seq": 18 } } }
   ```

| event `type` | fields | meaning |
|---|---|---|
| `state` | `state`, `stopReason?`, `queued` | `running` / `requires_action` / `idle` (aligned with ACP v2 `state_update`) |
| `permission_request` | `requestId`, `toolCall`, `options` | an agent asked for permission |
| `permission_resolved` | `requestId`, `outcome`, `optionName?`, `by?` | answered (by device name) or cancelled |
| `elicitation_request` | `requestId`, `request` | an agent asked for structured input |
| `elicitation_resolved` | `requestId`, `action`, `by?` | |
| `dequeued` | `promptId`, `cancelled?` | a queued prompt started (or was dropped) |
| `error` | `message`, `code?` | turn failed, agent crashed, … |

User prompts are logged as `user_message_chunk` updates with
`_meta.codeaw = { mid, promptId, queued?, steered? }` so every device sees them.

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
| `_codeaw/session/reimport` | `{sessionId}` | `{epoch}` (clients get a `full` replay on next load) |
| `_codeaw/notify/info` | – | `{enabled, server?, topic?}` |
| `_codeaw/notify/test` | – | `{sent}` |

File-system methods only accept paths inside the configured workspaces or a
known session `cwd`.

## Extension notifications

| direction | method | params |
|---|---|---|
| bridge → client | `_codeaw/activity` | `{sessionId, agentId, state, pending, queued, title?, updatedAt?}` — sent to **all** connections, attached or not |
| bridge → client | `_codeaw/replay` | see `session/load` |
| bridge → client | `_codeaw/event` | see event log |
| client → bridge | `_codeaw/client/state` | `{foreground: bool, activeSessionId?}` |
| client → bridge | `_codeaw/session/detach` | `{sessionId}` — stop pushing this session's updates/requests to this connection |

## Push notifications

When an event needs attention (permission/elicitation request, turn finished,
error) and **no client is connected at all**, the bridge waits
`notifications.ntfy.delaySeconds` and, if still unanswered and still nobody is
connected, publishes to ntfy with `click = codeaw://session/<sessionId>`.
Message text contains only the agent name and the kind of event unless
`includeDetails: true`.
