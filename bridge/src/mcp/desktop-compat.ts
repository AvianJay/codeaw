import type * as acp from "@agentclientprotocol/sdk";
import { ToolError, type McpHost, type McpTool } from "./tools.js";

/**
 * A chat begun in the Claude desktop app carries that app's instructions in its transcript,
 * and Claude Code replays them when codeaw resumes it. They require a task list and a
 * wrap-up through the app's own `ccd_turn` MCP server on every turn. codeaw serves those
 * two tools under the same name for such chats, so the model's habitual calls work, and
 * its instructions say which of the app's other tools do not exist here.
 */
export const DESKTOP_TURN_SERVER = "ccd_turn";

const MAX_STEPS = 50;
const MAX_STEP_LENGTH = 300;
const MAX_RECAP_LENGTH = 2000;
const MAX_BUTTONS = 4;
const MAX_BUTTON_LENGTH = 120;
const STATUSES = new Set(["pending", "in_progress", "completed"]);

export function desktopTurnInstructions(): string {
  return [
    "This chat began in the Claude desktop app. It now continues through codeaw, from the user's phone, so the desktop app's own tools are gone.",
    `codeaw serves two of them under the same names: mcp__${DESKTOP_TURN_SERVER}__update_plan shows your task list in the codeaw app, and mcp__${DESKTOP_TURN_SERVER}__wrap_up records your recap and shows its question's buttons as tappable replies.`,
    "Every other desktop-app tool does not exist here and cannot be loaded: ccd_session, ccd_session_mgmt, ccd_view, ccd_pr, ccd_settings, ccd_window, preview_* and the browser tools. Do not call them or search for them.",
    "Earlier instructions about starting, offering or linking other sessions, panes and terminal tabs no longer apply: do that work here, or tell the user what to do.",
    "Links such as (#local_…) or (#terminal/…) do not open on the phone; name the session, file or tab in plain words instead.",
  ].join("\n");
}

function parseItems(raw: unknown): Array<{ content: string; status: acp.PlanEntryStatus }> {
  let value = raw;
  // Models sometimes send the list JSON-encoded.
  if (typeof value === "string") {
    try { value = JSON.parse(value); }
    catch { throw new ToolError("items must be a list of {content, status} objects"); }
  }
  if (!Array.isArray(value)) throw new ToolError("items must be a list of {content, status} objects");
  if (value.length > MAX_STEPS) throw new ToolError(`A plan can have at most ${MAX_STEPS} steps`);
  return value.map((item, index) => {
    const entry = typeof item === "string" ? { content: item } : item as { content?: unknown; status?: unknown } | null;
    const content = typeof entry?.content === "string" ? entry.content.trim() : "";
    if (!content) throw new ToolError(`Step ${index + 1} needs content`);
    const status = entry?.status ?? "pending";
    if (typeof status !== "string" || !STATUSES.has(status)) throw new ToolError(`Step ${index + 1} has an unknown status; use pending, in_progress or completed`);
    return { content: content.length > MAX_STEP_LENGTH ? content.slice(0, MAX_STEP_LENGTH - 1) + "…" : content, status: status as acp.PlanEntryStatus };
  });
}

function updatePlan(args: Record<string, unknown>, sessionId: string, host: McpHost): string {
  if (!host.mcpSession(sessionId)) throw new ToolError("This chat no longer exists in codeaw");
  const given = args.items !== undefined && args.items !== null && args.items !== "";
  let steps = given ? parseItems(args.items) : (host.plan(sessionId) ?? []).map(({ content, status }) => ({ content, status }));
  if (!steps.length) throw new ToolError("There is no plan yet; send items with the whole list first");
  if (args.advance === true) {
    steps = steps.map((step) => ({ ...step }));
    const current = steps.findIndex((step) => step.status === "in_progress");
    if (current >= 0) steps[current].status = "completed";
    const next = steps.findIndex((step, index) => index > current && step.status === "pending");
    if (next >= 0) steps[next].status = "in_progress";
  }
  host.showPlan(sessionId, steps.map((step) => ({ content: step.content, status: step.status, priority: "medium" as const })));
  const active = steps.findIndex((step) => step.status === "in_progress");
  if (given && args.advance !== true) return `Plan shown (${steps.length} steps).`;
  if (active >= 0) return `Plan updated: step ${active + 1} of ${steps.length} is in progress.`;
  return steps.every((step) => step.status === "completed") ? `Plan updated: all ${steps.length} steps are done.` : `Plan updated (${steps.length} steps).`;
}

function buttonsOf(args: Record<string, unknown>): string[] {
  const raw = args.buttons ?? args.options ?? args.replies;
  if (raw === undefined || raw === null) return [];
  if (!Array.isArray(raw)) throw new ToolError("buttons must be a list of short labels");
  const buttons: string[] = [];
  for (const item of raw) {
    const label = typeof item === "string" ? item : (item as { label?: unknown; text?: unknown } | null)?.label ?? (item as { text?: unknown } | null)?.text;
    if (typeof label !== "string" || !label.trim()) throw new ToolError("Every button needs a label");
    const trimmed = label.trim();
    if (trimmed.length > MAX_BUTTON_LENGTH) throw new ToolError(`Button labels are at most ${MAX_BUTTON_LENGTH} characters`);
    if (!buttons.includes(trimmed)) buttons.push(trimmed);
  }
  if (buttons.length > MAX_BUTTONS) throw new ToolError(`Offer at most ${MAX_BUTTONS} buttons`);
  return buttons;
}

function wrapUp(args: Record<string, unknown>, sessionId: string, host: McpHost): string {
  if (!host.mcpSession(sessionId)) throw new ToolError("This chat no longer exists in codeaw");
  const recap = typeof args.recap === "string" ? args.recap.trim() : "";
  if (recap.length > MAX_RECAP_LENGTH) throw new ToolError(`recap is longer than ${MAX_RECAP_LENGTH} characters; shorten it`);
  const buttons = buttonsOf(args);
  // A finished plan should not stay on screen as if work were still going on.
  const plan = host.plan(sessionId);
  if (plan?.length && plan.some((step) => step.status !== "completed")) {
    host.showPlan(sessionId, plan.map((step) => ({ ...step, status: step.status === "in_progress" ? "completed" : step.status })));
  }
  if (buttons.length) host.showCard(sessionId, { kind: "replies", replies: buttons });
  const question = typeof args.question === "string" ? args.question.trim() : "";
  return [
    "Recorded.",
    buttons.length ? `The buttons are shown as tappable replies under your message${question ? "; put the question itself in your closing message" : ""}.` : "",
    "The codeaw app shows no separate next-step box: write your closing message now, the last thing you say this turn, with your answer in full.",
  ].filter(Boolean).join(" ");
}

export const DESKTOP_TURN_TOOLS: McpTool[] = [
  {
    name: "update_plan",
    title: "Update the task list",
    description:
      "Show or update your task list for this turn in the user's codeaw app. Send items with the whole plan when you start; " +
      "afterwards send {\"advance\": true} as each step finishes (it completes the current step and starts the next), " +
      "or items again when the plan changes.",
    inputSchema: {
      type: "object",
      properties: {
        items: {
          type: "array", maxItems: MAX_STEPS,
          description: "The whole plan, in order.",
          items: {
            type: "object",
            properties: {
              content: { type: "string", description: "What the step does." },
              status: { type: "string", enum: ["pending", "in_progress", "completed"] },
            },
            required: ["content", "status"],
          },
        },
        advance: { type: "boolean", description: "Complete the step in progress and start the next pending one." },
        scope: { type: "string", description: "Accepted for compatibility; codeaw ignores it." },
      },
    },
    run: updatePlan,
  },
  {
    name: "wrap_up",
    title: "Wrap up the turn",
    description:
      "Call once when this turn's work is done, before your closing message: a short recap of what is now true, " +
      "and, when the user has a decision to make, one short question with one-to-three-word buttons that answer it.",
    inputSchema: {
      type: "object",
      properties: {
        recap: { type: "string", maxLength: MAX_RECAP_LENGTH, description: "Two or three sentences on what is now true, including what is not done or not verified." },
        question: { type: "string", description: "Optional: the decision left to the user." },
        buttons: { type: "array", maxItems: MAX_BUTTONS, items: { type: "string", maxLength: MAX_BUTTON_LENGTH }, description: "Optional: short answers to the question." },
      },
      required: ["recap"],
    },
    run: wrapUp,
  },
];
