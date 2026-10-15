import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type * as acp from "@agentclientprotocol/sdk";
import { ClaudeWorkflows, taskNotification } from "../src/backend/claude-workflows.js";
import { lazyToolEntry } from "../src/session/history.js";
import type { LogEntry } from "../src/session/types.js";

let root: string;
let dir: string;
let transcript: string;

beforeEach(() => {
  root = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-workflow-"));
  dir = path.join(root, "project", "session", "subagents", "workflows", "wf_1");
  fs.mkdirSync(dir, { recursive: true });
  transcript = path.join(root, "project", "session.jsonl");
  fs.writeFileSync(transcript, JSON.stringify({ type: "user", message: { content: "earlier" } }) + "\n");
});

afterEach(() => fs.rmSync(root, { recursive: true, force: true }));

function launch(extra: Record<string, unknown> = {}): acp.SessionNotification {
  return { sessionId: "s1", update: {
    sessionUpdate: "tool_call_update", toolCallId: "toolu_wf",
    _meta: { claudeCode: { toolName: "Workflow", toolResponse: {
      status: "async_launched", taskId: "w1", runId: "wf_1", workflowName: "review",
      summary: "Review the change", transcriptDir: dir, ...extra,
    } } },
  } as acp.SessionUpdate };
}

function journal(entry: Record<string, unknown>): void {
  fs.appendFileSync(path.join(dir, "journal.jsonl"), JSON.stringify(entry) + "\n");
}

function notify(status: string, outputFile?: string): void {
  const content = `<task-notification>\n<task-id>w1</task-id>\n<tool-use-id>toolu_wf</tool-use-id>\n` +
    (outputFile ? `<output-file>${outputFile}</output-file>\n` : "") +
    `<status>${status}</status>\n<summary>Dynamic workflow &quot;Review&quot; ${status}</summary>\n<result>{"ok":true}</result>\n</task-notification>`;
  fs.appendFileSync(transcript, JSON.stringify({ type: "queue-operation", operation: "enqueue", content }) + "\n");
}

function monitor(): { workflows: ClaudeWorkflows; sent: any[] } {
  const sent: any[] = [];
  const workflows = new ClaudeWorkflows((params) => sent.push(params), 60_000);
  return { workflows, sent };
}

describe("Claude workflow runs", () => {
  it("parses Claude Code task notifications", () => {
    expect(taskNotification("<task-notification>\n<task-id>w1</task-id>\n<tool-use-id>toolu_1</tool-use-id>\n<status>killed</status>\n<summary>A &lt;b&gt; &amp; c</summary>\n<result><status>completed</status></result>\n</task-notification>"))
      .toEqual({ taskId: "w1", toolUseId: "toolu_1", status: "killed", summary: "A <b> & c", outputFile: undefined });
    expect(taskNotification("plain prompt")).toBeUndefined();
  });

  it("follows agents from the run journal and ends at the task notification", async () => {
    const { workflows, sent } = monitor();
    workflows.observe(launch());
    expect(sent.at(-1).update._meta.codeawWorkflow).toEqual({ state: "running", runId: "wf_1", taskId: "w1", name: "review", summary: "Review the change" });
    expect(workflows.active("s1")).toBe(true);

    fs.writeFileSync(path.join(dir, "agent-a1.meta.json"), JSON.stringify({ description: "design:brand", workflowPhase: "Design", model: "opus" }));
    fs.writeFileSync(path.join(dir, "agent-a1.jsonl"), [
      { type: "user", message: { role: "user", content: "[Workflow harness — user request] The harness relays the request:\n  design the splash" } },
      { type: "user", message: { role: "user", content: [{ type: "text", text: "[Workflow harness — computed task] The computed task text follows:\n  Design a brand concept\n    - keep it short" }] } },
    ].map((entry) => JSON.stringify(entry)).join("\n") + "\n");
    journal({ type: "launched" });
    journal({ type: "started", key: "k1", agentId: "a1", label: "design:brand", phase: "Design" });
    await workflows.poll();
    const started = sent.at(-1);
    expect(started.sessionId).toBe("s1");
    expect(started.update).toMatchObject({
      sessionUpdate: "tool_call", toolCallId: "workflow:toolu_wf:a1", title: "design:brand", kind: "think", status: "in_progress",
      rawInput: { description: "design:brand", prompt: "Design a brand concept\n  - keep it short" },
      _meta: { parentToolCallId: "toolu_wf", codeawWorkflowAgent: { agentId: "a1", runId: "wf_1", label: "design:brand", phase: "Design", model: "opus", state: "running" } },
    });

    journal({ type: "result", key: "k1", agentId: "a1", result: { name: "Concept" } });
    await workflows.poll();
    const done = sent.at(-1).update;
    expect(done).toMatchObject({ sessionUpdate: "tool_call_update", toolCallId: "workflow:toolu_wf:a1", status: "completed" });
    expect(done.content[0].content.text).toContain("\"name\": \"Concept\"");

    const output = path.join(root, "w1.output");
    fs.writeFileSync(output, JSON.stringify({ summary: "Review the change", agentCount: 1, logs: ["1/1 ready"], result: { ok: true }, totalTokens: 10, totalToolCalls: 2 }));
    notify("completed", output);
    await workflows.poll();
    const ended = sent.at(-1).update;
    expect(ended.toolCallId).toBe("toolu_wf");
    expect(ended._meta.codeawWorkflow).toMatchObject({ state: "completed", result: "Dynamic workflow \"Review\" completed" });
    expect(ended.rawOutput).toMatchObject({ logs: ["1/1 ready"], totalToolCalls: 2 });
    expect(workflows.active("s1")).toBe(false);

    const count = sent.length;
    journal({ type: "started", key: "k2", agentId: "late" });
    await workflows.poll();
    expect(sent.length).toBe(count);
  });

  it("consumes only complete journal lines", async () => {
    const { workflows, sent } = monitor();
    await workflows.poll();
    workflows.observe(launch());
    const line = JSON.stringify({ type: "started", key: "k", agentId: "a1", label: "judge:ux", phase: "Judge" });
    fs.appendFileSync(path.join(dir, "journal.jsonl"), line.slice(0, 20));
    await workflows.poll();
    expect(sent).toHaveLength(1);
    fs.appendFileSync(path.join(dir, "journal.jsonl"), line.slice(20) + "\n");
    await workflows.poll();
    expect(sent.at(-1).update.title).toBe("judge:ux");
  });

  it("stops unfinished agents with the run and ignores replays", async () => {
    const { workflows, sent } = monitor();
    workflows.observe({ sessionId: "s1", update: { sessionUpdate: "tool_call_update", toolCallId: "old", _meta: { claudeCode: { toolName: "Workflow" } } } as acp.SessionUpdate });
    workflows.observe(launch({ status: "remote_launched" }));
    expect(sent).toEqual([]);

    workflows.observe(launch());
    workflows.observe(launch());
    journal({ type: "started", key: "k", agentId: "a1", label: "judge:eng", phase: "Judge" });
    journal({ type: "started", key: "k2", agentId: "a2", label: "judge:ux", phase: "Judge" });
    journal({ type: "failed", key: "k2", agentId: "a2" });
    await workflows.poll();
    expect(sent.at(-1).update).toMatchObject({ toolCallId: "workflow:toolu_wf:a2", status: "failed" });
    workflows.stop("other");
    expect(workflows.active("s1")).toBe(true);
    workflows.stop("s1");
    const [agent, run] = sent.slice(-2).map((p) => p.update);
    expect(agent).toMatchObject({ toolCallId: "workflow:toolu_wf:a1", status: "failed", _meta: { codeawWorkflowAgent: { state: "stopped" } } });
    expect(run._meta.codeawWorkflow.state).toBe("stopped");
    expect(sent.filter((p) => p.update._meta?.codeawWorkflow?.state === "running")).toHaveLength(1);
  });

  it("keeps the run lifecycle in a deferred history header", async () => {
    const { workflows, sent } = monitor();
    const script = "export const meta = { name: 'review' }\n" + "x".repeat(8000);
    workflows.observe(launch());
    const header = lazyToolEntry({ seq: 9, t: 0, kind: "update", update: {
      sessionUpdate: "tool_call", toolCallId: "toolu_wf", title: "Workflow", rawInput: { script },
      _meta: { ...(launch().update as any)._meta, ...sent[0].update._meta },
    } } as LogEntry);
    const update = (header as any).update;
    expect(update.rawInput).toBeUndefined();
    expect(update._meta.claudeCode).toEqual({ toolName: "Workflow" });
    expect(update._meta.codeawWorkflow).toMatchObject({ state: "running", name: "review", summary: "Review the change" });
    expect(update._meta.codeaw.deferredTool.seq).toBe(9);
  });

  it("maps a killed run from the transcript", async () => {
    const { workflows, sent } = monitor();
    workflows.observe(launch());
    notify("killed");
    await workflows.poll();
    expect(sent.at(-1).update._meta.codeawWorkflow.state).toBe("stopped");
    expect(sent.at(-1).update.rawOutput).toBeUndefined();
  });
});
