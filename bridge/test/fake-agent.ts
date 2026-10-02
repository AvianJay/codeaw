/**
 * Scriptable ACP agent used by the tests (and for UI work without spending tokens).
 * Behaviour is chosen by the first word of the prompt:
 *   echo <text>   stream <text> in three chunks
 *   tool          shell-like tool call with streamed terminal output
 *   edit          edit tool call with a diff, then a result that overwrites content (Kimi style)
 *   perm          tool call that asks for permission
 *   elicit        ask a form question (AskUserQuestion style)
 *   slow <n>      n chunks, 40 ms apart; honours cancel and steering
 *   title <text>  session_info_update
 *   crash         exit the process mid-turn
 *   image         report the image block it received
 * State is persisted in $FAKE_AGENT_STATE so list/load/resume work across restarts.
 */
import fs from "node:fs";
import crypto from "node:crypto";
import { Readable, Writable } from "node:stream";
import * as acp from "@agentclientprotocol/sdk";

interface StoredSession {
  cwd: string;
  title?: string;
  updatedAt: string;
  mode: string;
  history: acp.SessionUpdate[];
}

const stateFile = process.env.FAKE_AGENT_STATE;
const steering = process.env.FAKE_AGENT_STEERING === "1";
const sessions: Record<string, StoredSession> = stateFile && fs.existsSync(stateFile) ? JSON.parse(fs.readFileSync(stateFile, "utf8")) : {};
const live = new Map<string, { cancelled: boolean; steer: string[]; running: boolean }>();

function save(): void {
  if (stateFile) fs.writeFileSync(stateFile, JSON.stringify(sessions));
}

function configOptions(mode: string): acp.SessionConfigOption[] {
  return [
    {
      id: "mode",
      name: "Mode",
      category: "mode",
      type: "select",
      currentValue: mode,
      options: [
        { value: "ask", name: "Ask" },
        { value: "code", name: "Code" },
      ],
    } as acp.SessionConfigOption,
  ];
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

const app = acp
  .agent({ name: "fake-agent" })
  .onRequest("initialize", () => ({
    protocolVersion: acp.PROTOCOL_VERSION,
    agentCapabilities: {
      loadSession: true,
      promptCapabilities: { image: true, embeddedContext: true },
      sessionCapabilities: { list: {}, resume: {}, close: {}, delete: {} },
    },
    agentInfo: { name: "fake-agent", version: "1.0.0" },
    authMethods: [],
    ...(steering ? { _meta: { steering: { supported: true } } } : {}),
  }))
  .onRequest("session/new", (ctx) => {
    const id = "s" + crypto.randomBytes(4).toString("hex");
    sessions[id] = { cwd: ctx.params.cwd, updatedAt: new Date().toISOString(), mode: "ask", history: [] };
    save();
    live.set(id, { cancelled: false, steer: [], running: false });
    setTimeout(() => {
      void ctx.client.notify("session/update", {
        sessionId: id,
        update: { sessionUpdate: "available_commands_update", availableCommands: [{ name: "hello", description: "say hi", input: null }] },
      });
    }, 0);
    return { sessionId: id, configOptions: configOptions("ask"), modes: { currentModeId: "ask", availableModes: [{ id: "ask", name: "Ask" }, { id: "code", name: "Code" }] } };
  })
  .onRequest("session/list", () => ({
    sessions: Object.entries(sessions).map(([sessionId, s]) => ({ sessionId, cwd: s.cwd, title: s.title ?? null, updatedAt: s.updatedAt })),
  }))
  .onRequest("session/load", async (ctx) => {
    const s = sessions[ctx.params.sessionId];
    if (!s) throw acp.RequestError.invalidParams(undefined, "unknown session");
    live.set(ctx.params.sessionId, live.get(ctx.params.sessionId) ?? { cancelled: false, steer: [], running: false });
    for (const update of s.history) await ctx.client.notify("session/update", { sessionId: ctx.params.sessionId, update });
    return { configOptions: configOptions(s.mode) };
  })
  .onRequest("session/resume", (ctx) => {
    const s = sessions[ctx.params.sessionId];
    if (!s) throw acp.RequestError.invalidParams(undefined, "unknown session");
    live.set(ctx.params.sessionId, live.get(ctx.params.sessionId) ?? { cancelled: false, steer: [], running: false });
    // Like Codex: resume resets the mode.
    s.mode = "ask";
    return { configOptions: configOptions(s.mode) };
  })
  .onRequest("session/close", (ctx) => {
    live.delete(ctx.params.sessionId);
    return {};
  })
  .onRequest("session/delete", (ctx) => {
    delete sessions[ctx.params.sessionId];
    save();
    return {};
  })
  .onRequest("session/set_config_option", (ctx) => {
    const s = sessions[ctx.params.sessionId];
    s.mode = String((ctx.params as any).value);
    save();
    return { configOptions: configOptions(s.mode) };
  })
  .onNotification("session/cancel", (ctx) => {
    const l = live.get(ctx.params.sessionId);
    if (l) l.cancelled = true;
  })
  .onRequest("_session/steering", (p: unknown) => p as { sessionId: string; prompt: acp.ContentBlock[] }, (ctx) => {
    const l = live.get(ctx.params.sessionId);
    if (!l?.running) return { outcome: "promptRequired", reason: "noRunningTurn" };
    l.steer.push(ctx.params.prompt.map((b: any) => b.text ?? "").join(""));
    return { outcome: "injected" };
  })
  .onRequest("session/prompt", async (ctx) => {
    const sessionId = ctx.params.sessionId;
    const s = sessions[sessionId];
    if (!s) throw acp.RequestError.invalidParams(undefined, "unknown session");
    const l = live.get(sessionId);
    if (!l) throw acp.RequestError.invalidRequest(undefined, "session not loaded");
    l.cancelled = false;
    l.running = true;
    const send = async (update: acp.SessionUpdate) => {
      s.history.push(update);
      await ctx.client.notify("session/update", { sessionId, update });
    };
    const say = (text: string, messageId = "a" + crypto.randomBytes(3).toString("hex")) =>
      send({ sessionUpdate: "agent_message_chunk", messageId, content: { type: "text", text } });
    const text = ctx.params.prompt.map((b: any) => (b.type === "text" ? b.text : "")).join(" ").trim();
    s.history.push({ sessionUpdate: "user_message_chunk", content: { type: "text", text } });
    const [cmd, ...rest] = text.split(/\s+/);
    const arg = rest.join(" ");
    try {
      switch (cmd) {
        case "echo": {
          const id = "m" + crypto.randomBytes(3).toString("hex");
          const third = Math.ceil(arg.length / 3);
          for (let i = 0; i < 3; i++) await say(arg.slice(i * third, (i + 1) * third), id);
          break;
        }
        case "tool": {
          await send({ sessionUpdate: "tool_call", toolCallId: "t1", title: "npm test", kind: "execute", status: "pending", content: [{ type: "terminal", terminalId: "t1" }], _meta: { terminal_info: { terminal_id: "t1" } } } as any);
          await send({ sessionUpdate: "tool_call_update", toolCallId: "t1", status: "in_progress", _meta: { terminal_output: { terminal_id: "t1", data: "line1\n" } } } as any);
          await send({ sessionUpdate: "tool_call_update", toolCallId: "t1", _meta: { terminal_output: { terminal_id: "t1", data: "line2\n" } } } as any);
          await send({ sessionUpdate: "tool_call_update", toolCallId: "t1", status: "completed", rawOutput: { exit_code: 0 }, _meta: { terminal_exit: { terminal_id: "t1", exit_code: 0, signal: null } } } as any);
          await say("done");
          break;
        }
        case "edit": {
          await send({ sessionUpdate: "tool_call", toolCallId: "e1", title: "Edit a.ts", kind: "edit", status: "in_progress", content: [{ type: "diff", path: "/p/a.ts", oldText: "foo()", newText: "bar()" }], locations: [{ path: "/p/a.ts", line: 3 }] });
          await send({ sessionUpdate: "tool_call_update", toolCallId: "e1", status: "completed", content: [{ type: "content", content: { type: "text", text: "Edited 1 line" } }] });
          break;
        }
        case "perm": {
          await send({ sessionUpdate: "tool_call", toolCallId: "p1", title: "rm -rf build", kind: "delete", status: "pending" });
          const answer = await ctx.client.request("session/request_permission", {
            sessionId,
            toolCall: { toolCallId: "p1", title: "rm -rf build" },
            options: [
              { optionId: "allow", name: "Allow", kind: "allow_once" },
              { optionId: "reject", name: "Reject", kind: "reject_once" },
            ],
          });
          if (answer.outcome.outcome === "cancelled") return { stopReason: "cancelled" };
          const ok = answer.outcome.optionId === "allow";
          await send({ sessionUpdate: "tool_call_update", toolCallId: "p1", status: ok ? "completed" : "failed" });
          await say(ok ? "allowed" : "rejected");
          break;
        }
        case "elicit": {
          const r: any = await ctx.client.request("elicitation/create", {
            mode: "form",
            sessionId,
            message: "Which framework?",
            requestedSchema: { type: "object", properties: { question_0: { type: "string", title: "Framework", oneOf: [{ const: "React", title: "React" }, { const: "Vue", title: "Vue" }] } } },
          } as any);
          await say(r.action === "accept" ? `answer=${r.content?.question_0}` : `action=${r.action}`);
          break;
        }
        case "slow": {
          const n = Number(arg) || 20;
          const id = "slow" + crypto.randomBytes(3).toString("hex");
          for (let i = 0; i < n; i++) {
            if (l.cancelled) return { stopReason: "cancelled" };
            while (l.steer.length) await say(`[steer:${l.steer.shift()}]`, "st" + i);
            await say(`${i} `, id);
            await sleep(40);
          }
          if (l.cancelled) return { stopReason: "cancelled" };
          break;
        }
        case "title": {
          s.title = arg;
          await send({ sessionUpdate: "session_info_update", title: arg });
          await say("ok");
          break;
        }
        case "crash": {
          await say("about to crash");
          setTimeout(() => process.exit(3), 20);
          await sleep(1000);
          break;
        }
        case "image": {
          const img: any = ctx.params.prompt.find((b: any) => b.type === "image");
          await say(img ? `got image ${img.mimeType} ${img.data.length}` : "no image");
          break;
        }
        default:
          await say(`unknown command: ${text}`);
      }
      return { stopReason: "end_turn" };
    } finally {
      l.running = false;
      s.updatedAt = new Date().toISOString();
      save();
    }
  });

app.connect(
  acp.ndJsonStream(
    Writable.toWeb(process.stdout) as WritableStream<Uint8Array>,
    Readable.toWeb(process.stdin) as unknown as ReadableStream<Uint8Array>,
  ),
);
