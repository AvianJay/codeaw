import fs from "node:fs";
import path from "node:path";
import type * as acp from "@agentclientprotocol/sdk";
import { mimeFor } from "../server/ext.js";
import type { Card, CardFile } from "../session/types.js";
import { expandHome, realPath } from "../util/paths.js";

/** The name agents see; their tool ids become e.g. `mcp__codeaw__show_files`. */
export const MCP_SERVER_NAME = "codeaw";

/** How a notification reached the user. */
export type NotifyDelivery = "watching" | "devices" | "push" | "none";

/** What the tools need from the session layer. */
export interface McpHost {
  /** Undefined once the chat is gone. */
  mcpSession(sessionId: string): { cwd: string } | undefined;
  /** Adds a card to the chat. `share` lists files paired devices may now read. */
  showCard(sessionId: string, card: Card, share?: string[]): void;
  notifyUser(sessionId: string, notice: { title?: string; message: string; urgent: boolean }): Promise<NotifyDelivery>;
  /** Replaces the task list shown above the composer. */
  showPlan(sessionId: string, entries: acp.PlanEntry[]): void;
  /** The task list the chat shows now, if any. */
  plan(sessionId: string): acp.PlanEntry[] | undefined;
}

/** A mistake in the call that the model can correct; returned as a tool error, not a protocol error. */
export class ToolError extends Error {}

export interface McpTool {
  name: string;
  title: string;
  description: string;
  inputSchema: Record<string, unknown>;
  run(args: Record<string, unknown>, sessionId: string, host: McpHost): Promise<string> | string;
}

const MAX_FILES = 8;
const MAX_REPLIES = 6;
const MAX_REPLY_LENGTH = 120;
const MAX_TITLE_LENGTH = 80;
const MAX_CAPTION_LENGTH = 200;
const MAX_MESSAGE_LENGTH = 500;
const NOTIFY_WINDOW_MS = 60_000;
const NOTIFY_LIMIT = 4;

function text(value: unknown, name: string, limit: number, required = false): string | undefined {
  if (value === undefined || value === null || value === "") {
    if (required) throw new ToolError(`${name} is required`);
    return undefined;
  }
  if (typeof value !== "string") throw new ToolError(`${name} must be a string`);
  const trimmed = value.trim();
  if (!trimmed) {
    if (required) throw new ToolError(`${name} is required`);
    return undefined;
  }
  if (trimmed.length > limit) throw new ToolError(`${name} is longer than ${limit} characters; shorten it`);
  return trimmed;
}

function showFiles(args: Record<string, unknown>, sessionId: string, host: McpHost): string {
  const session = host.mcpSession(sessionId);
  if (!session) throw new ToolError("This chat no longer exists in codeaw");
  const wanted = args.files;
  if (!Array.isArray(wanted) || wanted.length === 0) throw new ToolError("files must list at least one file");
  if (wanted.length > MAX_FILES) throw new ToolError(`Show at most ${MAX_FILES} files per call`);
  const files: CardFile[] = [];
  const problems: string[] = [];
  for (const item of wanted) {
    // Models often pass a bare path where an object is expected.
    const entry = typeof item === "string" ? { path: item } : item as { path?: unknown; caption?: unknown } | null;
    if (!entry || typeof entry.path !== "string" || !entry.path.trim()) throw new ToolError("Every file needs a path");
    const caption = text(entry.caption, "caption", MAX_CAPTION_LENGTH);
    const given = expandHome(entry.path.trim());
    const resolved = realPath(path.isAbsolute(given) ? given : path.resolve(session.cwd, given));
    let stat: fs.Stats;
    try { stat = fs.statSync(resolved); }
    catch { problems.push(`${entry.path}: not found`); continue; }
    if (stat.isDirectory()) { problems.push(`${entry.path}: is a folder; show the files inside it, or an archive of it`); continue; }
    if (!stat.isFile()) { problems.push(`${entry.path}: not a regular file`); continue; }
    if (files.some((file) => file.path === resolved)) continue;
    const mimeType = mimeFor(resolved);
    files.push({ path: resolved, name: path.basename(resolved), size: stat.size, ...(mimeType ? { mimeType } : {}), ...(caption ? { caption } : {}) });
  }
  // Showing half of what was asked would look like the whole answer.
  if (problems.length) throw new ToolError(`Nothing was shown. ${problems.join("; ")}. Relative paths resolve against ${session.cwd}.`);
  const title = text(args.title, "title", MAX_TITLE_LENGTH);
  host.showCard(sessionId, { kind: "files", ...(title ? { title } : {}), files }, files.map((file) => file.path));
  return `Shown in the user's chat: ${files.map((file) => file.name).join(", ")}. They can preview, open, download or share ${files.length === 1 ? "it" : "them"} from the app.`;
}

function suggestReplies(args: Record<string, unknown>, sessionId: string, host: McpHost): string {
  if (!host.mcpSession(sessionId)) throw new ToolError("This chat no longer exists in codeaw");
  if (!Array.isArray(args.replies) || args.replies.length === 0) throw new ToolError("replies must list at least one reply");
  const replies: string[] = [];
  for (const item of args.replies) {
    const reply = text(item, "Each reply", MAX_REPLY_LENGTH, true)!;
    if (!replies.includes(reply)) replies.push(reply);
  }
  if (replies.length > MAX_REPLIES) throw new ToolError(`Suggest at most ${MAX_REPLIES} replies`);
  host.showCard(sessionId, { kind: "replies", replies });
  return "The replies are shown as buttons under your message. Finish your turn now: the user answers by tapping one or by typing something else.";
}

/** Recent notification times per chat; a looping agent must not flood a phone. */
const notified = new Map<string, number[]>();

async function notify(args: Record<string, unknown>, sessionId: string, host: McpHost): Promise<string> {
  if (!host.mcpSession(sessionId)) throw new ToolError("This chat no longer exists in codeaw");
  const message = text(args.message, "message", MAX_MESSAGE_LENGTH, true)!;
  const title = text(args.title, "title", MAX_TITLE_LENGTH);
  const urgent = args.urgent === true;
  const now = Date.now();
  const recent = (notified.get(sessionId) ?? []).filter((at) => now - at < NOTIFY_WINDOW_MS);
  if (recent.length >= NOTIFY_LIMIT) throw new ToolError("Too many notifications from this chat in the last minute. Put the rest in your reply instead.");
  recent.push(now);
  notified.set(sessionId, recent);
  if (notified.size > 512) notified.delete(notified.keys().next().value!);
  host.showCard(sessionId, { kind: "notice", ...(title ? { title } : {}), message, ...(urgent ? { urgent } : {}) });
  switch (await host.notifyUser(sessionId, { title, message, urgent })) {
    case "watching": return "The user has this chat open and sees the message there, so no notification was needed.";
    case "devices": return "Sent to the user's connected devices.";
    case "push": return "No device is connected right now; a push notification was sent.";
    case "none": return "No device is connected and this bridge has no push service configured. The message stays in the chat for when the user returns.";
  }
}

export const MCP_TOOLS: McpTool[] = [
  {
    name: "show_files",
    title: "Show files in the chat",
    description:
      "Put files from this computer into the user's codeaw chat. The user is usually on a phone and cannot open paths on this computer, " +
      "so use this for anything they should look at or keep: screenshots, generated images, charts, PDFs, logs, build outputs. " +
      "Images are previewed inline; other files can be opened, downloaded or shared from the app. " +
      "Files are shown, not uploaded anywhere else, and stay where they are on disk.",
    inputSchema: {
      type: "object",
      properties: {
        files: {
          type: "array", minItems: 1, maxItems: MAX_FILES,
          description: "Files to show, in display order.",
          items: {
            type: "object",
            properties: {
              path: { type: "string", description: "Absolute path, or a path relative to the chat's working directory." },
              caption: { type: "string", maxLength: MAX_CAPTION_LENGTH, description: "One short line shown with the file." },
            },
            required: ["path"],
            additionalProperties: false,
          },
        },
        title: { type: "string", maxLength: MAX_TITLE_LENGTH, description: "Optional heading for the group." },
      },
      required: ["files"],
      additionalProperties: false,
    },
    run: showFiles,
  },
  {
    name: "suggest_replies",
    title: "Suggest quick replies",
    description:
      "Offer the user short replies as tappable buttons, because typing on a phone is slow. " +
      "Call it right before you end a turn that asks a question or leaves clear next steps, with the answers the user is most likely to give " +
      "(for example \"Yes, commit it\", \"Run the tests first\"). Each reply is sent back verbatim as the user's next message, so write them in the user's voice and language. " +
      "This does not wait for an answer.",
    inputSchema: {
      type: "object",
      properties: {
        replies: {
          type: "array", minItems: 1, maxItems: MAX_REPLIES,
          items: { type: "string", maxLength: MAX_REPLY_LENGTH },
          description: "Two to four complete, distinct replies work best.",
        },
      },
      required: ["replies"],
      additionalProperties: false,
    },
    run: suggestReplies,
  },
  {
    name: "notify",
    title: "Notify the user",
    description:
      "Send a notification to the user's phone or other codeaw devices when something is worth interrupting them for mid-turn: " +
      "a long job finished, a result needs their eyes, or you are about to wait on something outside your control. " +
      "codeaw already notifies the user when a turn ends or a permission is needed, so do not use this for routine progress or at the end of a turn.",
    inputSchema: {
      type: "object",
      properties: {
        message: { type: "string", maxLength: MAX_MESSAGE_LENGTH, description: "What happened, in one or two plain sentences." },
        title: { type: "string", maxLength: MAX_TITLE_LENGTH, description: "Optional short headline." },
        urgent: { type: "boolean", description: "True only when the user must act soon." },
      },
      required: ["message"],
      additionalProperties: false,
    },
    run: notify,
  },
];

const TOOL_NAMES = new Set(MCP_TOOLS.map((tool) => tool.name));
/**
 * Every MCP server the bridge answers, with its tools. `ccd_turn` stands in for the Claude
 * desktop app's server of that name (see desktop-compat.ts, whose tool list a test compares).
 */
export const OWN_SERVERS: Readonly<Record<string, ReadonlySet<string>>> = {
  [MCP_SERVER_NAME]: TOOL_NAMES,
  ccd_turn: new Set(["update_plan", "wrap_up"]),
};
// Claude Code, Kimi and DeepSeek Harness report `mcp__<server>__<tool>`; codex-acp reports `mcp.<server>.<tool>`.
const TOOL_ID = /^mcp(?:__|\.)([a-z_]+?)(?:__|\.)([a-z_]+)$/;
const ownTool = (server: unknown, tool: unknown) =>
  typeof server === "string" && typeof tool === "string" && Object.hasOwn(OWN_SERVERS, server) && OWN_SERVERS[server].has(tool);

/**
 * True when a tool call reported by an agent is one of this server's tools. They only
 * present something to the user, so the bridge answers their permission requests itself.
 * Several reports of the same call may be given (the request and the logged call).
 */
export function isOwnToolCall(...toolCalls: unknown[]): boolean {
  const calls = toolCalls.filter((call): call is { title?: unknown; name?: unknown; kind?: unknown; rawInput?: any; _meta?: any } => !!call && typeof call === "object");
  const own = (id: unknown) => {
    const match = typeof id === "string" ? TOOL_ID.exec(id) : null;
    return !!match && ownTool(match[1], match[2]);
  };
  const input = (call: { rawInput?: any }) => call.rawInput && typeof call.rawInput === "object" ? call.rawInput : {};
  for (const call of calls) {
    // Claude names the tool itself; that outranks a title.
    const named = call._meta?.claudeCode?.toolName;
    if (typeof named === "string" && !own(named)) return false;
    // A shell command can be titled anything.
    if ("command" in input(call)) return false;
  }
  return calls.some((call) => {
    // codex-acp reports MCP calls as `execute`, with the server and tool in the input.
    if (ownTool(input(call).server, input(call).tool)) return true;
    if (own(call._meta?.claudeCode?.toolName)) return true;
    return call.kind !== "execute" && (own(call.name) || own(call.title));
  });
}
