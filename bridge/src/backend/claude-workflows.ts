import fs from "node:fs";
import path from "node:path";
import type * as acp from "@agentclientprotocol/sdk";

/**
 * Claude Code's Workflow tool returns as soon as its run is launched in the
 * background, and claude-agent-acp reports run progress only to AIR clients.
 * The run directory (`transcriptDir`) keeps a journal of started/finished
 * agents, and the session transcript receives a `<task-notification>` when the
 * run ends. Following both turns one launch into attributed child tool calls
 * plus a lifecycle on the Workflow card (see docs/protocol.md).
 */

export type WorkflowState = "running" | "completed" | "failed" | "stopped";

export interface TaskNotification {
  taskId?: string;
  toolUseId?: string;
  status?: string;
  summary?: string;
  outputFile?: string;
}

const POLL_MS = 1000;
/** The notification arrives after launch; a little overlap covers a run that ends at once. */
const TRANSCRIPT_BACKOFF = 256 * 1024;
const MAX_OUTPUT_BYTES = 512 * 1024;
const MAX_RESULT_CHARS = 64 * 1024;
const MAX_PROMPT_CHARS = 8 * 1024;
const PROMPT_HEAD_BYTES = 256 * 1024;
const COMPUTED_TASK = "[Workflow harness — computed task]";

const ENTITIES: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: "\"", apos: "'" };

function unescapeXml(text: string): string {
  return text.replace(/&(amp|lt|gt|quot|apos);/g, (_, name: string) => ENTITIES[name]);
}

function tag(text: string, name: string): string | undefined {
  const match = new RegExp(`<${name}>([\\s\\S]*?)</${name}>`).exec(text);
  const value = match?.[1].trim();
  return value ? unescapeXml(value) : undefined;
}

/** Claude Code's model-facing report that a background task ended. */
export function taskNotification(text: string): TaskNotification | undefined {
  const body = /<task-notification>([\s\S]*?)(?:<\/task-notification>|$)/.exec(text)?.[1];
  if (body === undefined) return undefined;
  // `<result>` can be large and may itself contain tag-like text.
  const head = body.split("<result>")[0];
  return {
    taskId: tag(head, "task-id"),
    toolUseId: tag(head, "tool-use-id"),
    status: tag(head, "status"),
    summary: tag(head, "summary"),
    outputFile: tag(head, "output-file"),
  };
}

export function workflowState(status: string | undefined): WorkflowState | undefined {
  if (status === "completed") return "completed";
  if (status === "failed") return "failed";
  if (status === "killed" || status === "stopped" || status === "cancelled") return "stopped";
  return undefined;
}

/**
 * Reads only complete lines appended since the previous call. With `backoff`,
 * the first read starts that many bytes before the end instead of at the start.
 */
class Tail {
  private offset?: number;
  private skipPartial = false;

  constructor(readonly file: string, private readonly backoff = Infinity) {}

  async lines(): Promise<string[]> {
    let handle: fs.promises.FileHandle;
    try {
      handle = await fs.promises.open(this.file, "r");
    } catch {
      return [];
    }
    try {
      const { size } = await handle.stat();
      if (this.offset === undefined) {
        this.offset = Math.max(0, size - this.backoff);
        this.skipPartial = this.offset > 0;
      }
      if (size < this.offset) this.offset = 0;
      if (size === this.offset) return [];
      const buffer = Buffer.alloc(size - this.offset);
      const { bytesRead } = await handle.read(buffer, 0, buffer.length, this.offset);
      const end = buffer.subarray(0, bytesRead).lastIndexOf(0x0a);
      if (end < 0) return [];
      this.offset += end + 1;
      const lines = buffer.subarray(0, end).toString("utf8").split("\n");
      if (this.skipPartial) {
        this.skipPartial = false;
        lines.shift();
      }
      return lines.map((line) => line.trim()).filter(Boolean);
    } finally {
      await handle.close();
    }
  }
}

interface WorkflowAgent {
  id: string;
  label?: string;
  phase?: string;
  model?: string;
  prompt?: string;
  state: WorkflowState;
}

interface WorkflowRun {
  sessionId: string;
  toolCallId: string;
  taskId?: string;
  runId?: string;
  name?: string;
  summary?: string;
  dir: string;
  journal: Tail;
  transcript: Tail;
  agents: Map<string, WorkflowAgent>;
}

function text(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function clip(value: string, limit: number): string {
  return value.length > limit ? `${value.slice(0, limit)}\n…（已截斷）` : value;
}

function parse(line: string): any {
  try {
    return JSON.parse(line);
  } catch {
    return undefined;
  }
}

/** The text of a transcript entry that can carry a queued task notification. */
function entryText(entry: any): string | undefined {
  const content = entry?.content ?? entry?.attachment?.prompt ?? entry?.message?.content;
  if (typeof content === "string") return content;
  if (Array.isArray(content)) return content.map((block: any) => (typeof block?.text === "string" ? block.text : "")).join("");
  return undefined;
}

export class ClaudeWorkflows {
  private readonly runs = new Map<string, WorkflowRun>();
  private timer?: NodeJS.Timeout;
  private polling?: Promise<void>;

  constructor(private readonly publish: (params: acp.SessionNotification) => void, private readonly pollMs = POLL_MS) {}

  /** Starts following a Workflow tool whose launch result names a local run directory. */
  observe(params: acp.SessionNotification): void {
    const update = params.update as any;
    if (update?.sessionUpdate !== "tool_call" && update?.sessionUpdate !== "tool_call_update") return;
    const claude = update._meta?.claudeCode;
    const response = claude?.toolResponse;
    if (claude?.toolName !== "Workflow" || response?.status !== "async_launched") return;
    const dir = text(response.transcriptDir);
    const toolCallId = text(update.toolCallId);
    if (!dir || !toolCallId || this.runs.has(toolCallId)) return;
    // `<project>/<session>/subagents/workflows/<run>` → `<project>/<session>.jsonl`
    const transcript = `${path.resolve(dir, "..", "..", "..")}.jsonl`;
    const run: WorkflowRun = {
      sessionId: params.sessionId, toolCallId, dir,
      taskId: text(response.taskId), runId: text(response.runId),
      name: text(response.workflowName), summary: text(response.summary),
      journal: new Tail(path.join(dir, "journal.jsonl")),
      transcript: new Tail(transcript, TRANSCRIPT_BACKOFF),
      agents: new Map(),
    };
    this.runs.set(toolCallId, run);
    this.reportRun(run, "running");
    this.timer ??= setInterval(() => void this.poll(), this.pollMs);
    this.timer.unref();
  }

  /** Whether the session still has a run that the agent process is executing. */
  active(sessionId: string): boolean {
    for (const run of this.runs.values()) if (run.sessionId === sessionId) return true;
    return false;
  }

  /** The agent or its session ended, which ends the runs it was executing. */
  stop(sessionId?: string): void {
    for (const run of [...this.runs.values()]) {
      if (sessionId !== undefined && run.sessionId !== sessionId) continue;
      this.finish(run, "stopped");
    }
  }

  /** One poll of every run; exposed so tests need no timers. */
  poll(): Promise<void> {
    this.polling ??= (async () => {
      for (const run of [...this.runs.values()]) {
        try {
          await this.pollRun(run);
        } catch {
          // A run directory that cannot be read leaves the launch card as it is.
        }
      }
    })().finally(() => { this.polling = undefined; });
    return this.polling;
  }

  private async pollRun(run: WorkflowRun): Promise<void> {
    for (const line of await run.journal.lines()) {
      if (!this.runs.has(run.toolCallId)) return;
      const entry = parse(line);
      const id = text(entry?.agentId);
      if (!id) continue;
      if (entry.type === "started") await this.started(run, id, entry);
      else if (entry.type === "result") await this.ended(run, id, "completed", entry.result);
      else if (entry.type === "failed") await this.ended(run, id, "failed", entry.error ?? entry.message);
    }
    for (const line of await run.transcript.lines()) {
      if (!this.runs.has(run.toolCallId)) return;
      if (!line.includes("task-notification")) continue;
      const body = entryText(parse(line));
      const notice = body ? taskNotification(body) : undefined;
      if (!notice || !(notice.toolUseId === run.toolCallId || (run.taskId && notice.taskId === run.taskId))) continue;
      const state = workflowState(notice.status);
      if (!state) continue;
      this.finish(run, state, notice.summary, await this.output(notice.outputFile));
      return;
    }
  }

  private async started(run: WorkflowRun, id: string, entry: any): Promise<void> {
    if (run.agents.has(id)) return;
    const meta = parse(await fs.promises.readFile(path.join(run.dir, `agent-${id}.meta.json`), "utf8").catch(() => ""));
    const agent: WorkflowAgent = {
      id, state: "running",
      label: text(entry.label) ?? text(meta?.description),
      phase: text(entry.phase) ?? text(meta?.workflowPhase),
      model: text(meta?.model),
      prompt: await this.prompt(run, id),
    };
    run.agents.set(id, agent);
    this.reportAgent(run, agent, true);
  }

  private async ended(run: WorkflowRun, id: string, state: WorkflowState, value: unknown): Promise<void> {
    let agent = run.agents.get(id);
    if (!agent) {
      // A resumed run returns cached results without starting the agent again.
      await this.started(run, id, {});
      agent = run.agents.get(id)!;
    }
    if (agent.state !== "running") return;
    agent.state = state;
    agent.prompt ??= await this.prompt(run, id);
    const body = typeof value === "string" ? value : value === undefined ? undefined : "```json\n" + JSON.stringify(value, null, 2) + "\n```";
    this.reportAgent(run, agent, false, body === undefined ? undefined : clip(body, MAX_RESULT_CHARS));
  }

  private finish(run: WorkflowRun, state: WorkflowState, summary?: string, output?: unknown): void {
    if (!this.runs.delete(run.toolCallId)) return;
    if (this.runs.size === 0 && this.timer) {
      clearInterval(this.timer);
      this.timer = undefined;
    }
    for (const agent of run.agents.values()) {
      if (agent.state !== "running") continue;
      agent.state = state === "failed" ? "failed" : "stopped";
      this.reportAgent(run, agent, false);
    }
    this.reportRun(run, state, summary, output);
  }

  /**
   * The prompt the script gave an agent. Current Claude Code frames it as an
   * indented "computed task" after relaying the user's request; older runs
   * start the transcript with the prompt itself.
   */
  private async prompt(run: WorkflowRun, id: string): Promise<string | undefined> {
    let handle: fs.promises.FileHandle | undefined;
    let first: string | undefined;
    try {
      handle = await fs.promises.open(path.join(run.dir, `agent-${id}.jsonl`), "r");
      const buffer = Buffer.alloc(PROMPT_HEAD_BYTES);
      const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0);
      for (const line of buffer.subarray(0, bytesRead).toString("utf8").split("\n")) {
        const entry = parse(line);
        if (entry?.type !== "user" || entry.isMeta) continue;
        const prompt = text(entryText(entry));
        if (!prompt) continue;
        if (prompt.startsWith(COMPUTED_TASK) && prompt.includes("\n")) {
          const body = prompt.slice(prompt.indexOf("\n") + 1).split("\n").map((l) => l.replace(/^ {2}/, "")).join("\n").trim();
          if (body) return clip(body, MAX_PROMPT_CHARS);
        }
        if (!prompt.startsWith("[Workflow harness")) first ??= prompt;
      }
    } catch {
      // The transcript appears shortly after the journal entry.
    } finally {
      await handle?.close();
    }
    return first === undefined ? undefined : clip(first, MAX_PROMPT_CHARS);
  }

  /** The workflow's return value, logs and totals, as the task's output file records them. */
  private async output(file: string | undefined): Promise<unknown> {
    if (!file) return undefined;
    try {
      const { size } = await fs.promises.stat(file);
      if (size > MAX_OUTPUT_BYTES) return undefined;
      const raw = await fs.promises.readFile(file, "utf8");
      return parse(raw) ?? clip(raw, MAX_RESULT_CHARS);
    } catch {
      return undefined;
    }
  }

  private reportRun(run: WorkflowRun, state: WorkflowState, summary?: string, output?: unknown): void {
    this.publish({ sessionId: run.sessionId, update: {
      sessionUpdate: "tool_call_update", toolCallId: run.toolCallId,
      ...(output !== undefined ? { rawOutput: output } : {}),
      _meta: { codeawWorkflow: {
        state,
        ...(run.runId ? { runId: run.runId } : {}),
        ...(run.taskId ? { taskId: run.taskId } : {}),
        ...(run.name ? { name: run.name } : {}),
        ...(run.summary ? { summary: run.summary } : {}),
        ...(summary ? { result: summary } : {}),
      } },
    } as acp.SessionUpdate });
  }

  private reportAgent(run: WorkflowRun, agent: WorkflowAgent, created: boolean, result?: string): void {
    const title = agent.label ?? agent.phase ?? "Workflow agent";
    this.publish({ sessionId: run.sessionId, update: {
      sessionUpdate: created ? "tool_call" : "tool_call_update",
      toolCallId: `workflow:${run.toolCallId}:${agent.id}`,
      title, kind: "think",
      status: agent.state === "running" ? "in_progress" : agent.state === "completed" ? "completed" : "failed",
      ...(agent.prompt ? { rawInput: { description: title, prompt: agent.prompt } } : {}),
      ...(result !== undefined ? { content: [{ type: "content", content: { type: "text", text: result } }] } : {}),
      _meta: {
        parentToolCallId: run.toolCallId,
        codeawWorkflowAgent: {
          agentId: agent.id, state: agent.state,
          ...(run.runId ? { runId: run.runId } : {}),
          ...(agent.label ? { label: agent.label } : {}),
          ...(agent.phase ? { phase: agent.phase } : {}),
          ...(agent.model ? { model: agent.model } : {}),
        },
      },
    } as acp.SessionUpdate });
  }
}
