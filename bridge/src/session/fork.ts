import * as acp from "@agentclientprotocol/sdk";
import { parentToolCallId } from "./subagent.js";
import { codeawMeta, type LogEntry } from "./types.js";

/** Where an edited prompt branches off its chat. */
export interface ForkPlan {
  /**
   * Main-thread agent message id the agent keeps (inclusive) through `session/fork`.
   * Absent when the edited prompt was the first one: the branch is a new session.
   */
  messageId?: string;
  /** Log entries the branch starts with, in order (seq not yet renumbered). */
  entries: LogEntry[];
}

function isMainUser(entry: LogEntry): boolean {
  return entry.kind === "update" && entry.update.sessionUpdate === "user_message_chunk" && !parentToolCallId(entry.update);
}

function agentMessageId(entry: LogEntry): string | undefined {
  if (entry.kind !== "update" || parentToolCallId(entry.update)) return undefined;
  const update = entry.update as any;
  if (update.sessionUpdate !== "agent_message_chunk" && update.sessionUpdate !== "agent_thought_chunk") return undefined;
  return typeof update.messageId === "string" && update.messageId ? update.messageId : undefined;
}

function promptIdOf(entry: LogEntry): string | undefined {
  if (entry.kind === "update") {
    const id = codeawMeta(entry.update).promptId;
    return typeof id === "string" ? id : undefined;
  }
  return entry.event.type === "prompt_receipt" || entry.event.type === "dequeued" ? entry.event.promptId : undefined;
}

/**
 * Finds the fork point for editing the main-thread user message `mid`.
 *
 * The branch keeps every turn before the edited prompt's turn, ending with the last
 * agent message (with an agent-supplied id) of those turns. Turns after that message
 * which produced no such id (e.g. cancelled before any output) cannot be kept by the
 * agent, so they are left out of the copied history as well.
 */
export function planFork(entries: LogEntry[], mid: string): ForkPlan {
  const index = entries.findIndex((e) => isMainUser(e) && codeawMeta((e as any).update).mid === mid);
  if (index < 0) throw acp.RequestError.invalidParams(undefined, "This message is not in the chat history; reload the chat and try again");
  const target = codeawMeta((entries[index] as any).update);
  const promptId: string | undefined = typeof target.promptId === "string" ? target.promptId : undefined;

  // Turn boundaries: a codeaw prompt starts at its first state event, a native
  // (imported) prompt at its first chunk. Queued prompts are logged earlier.
  const turnStart = new Map<string, number>();
  const nativeMids = new Set<unknown>();
  const boundaries: number[] = [];
  entries.forEach((e, i) => {
    if (e.kind === "event" && e.event.type === "state" && typeof e.event.turnPromptId === "string") {
      if (!turnStart.has(e.event.turnPromptId)) {
        turnStart.set(e.event.turnPromptId, i);
        boundaries.push(i);
      }
    } else if (isMainUser(e)) {
      const meta = codeawMeta((e as any).update);
      if (typeof meta.promptId !== "string" && !nativeMids.has(meta.mid)) {
        nativeMids.add(meta.mid);
        boundaries.push(i);
      }
    }
  });

  let cut = index;
  if (promptId) {
    const start = turnStart.get(promptId);
    const chunks = entries.filter((e) => isMainUser(e) && codeawMeta((e as any).update).promptId === promptId);
    const flags = chunks.map((e) => codeawMeta((e as any).update));
    if (start === undefined) {
      if (flags.some((f) => f.steered === true)) throw acp.RequestError.invalidRequest(undefined, "A message inserted into a running turn cannot be edited");
      if (flags.some((f) => f.queued === true)) throw acp.RequestError.invalidRequest(undefined, "This message has not started yet; remove it instead");
    } else cut = start;
  }

  let forkIndex = -1;
  for (let i = cut - 1; i >= 0; i--) {
    if (agentMessageId(entries[i])) {
      forkIndex = i;
      break;
    }
  }
  if (forkIndex < 0) {
    if (boundaries.some((b) => b < cut)) {
      throw acp.RequestError.invalidRequest(undefined, "The agent reported no message ids before this message, so the chat cannot branch here");
    }
    return { entries: [] };
  }

  const end = Math.min(cut, boundaries.find((b) => b > forkIndex) ?? cut);
  const kept = new Set<string>();
  for (const [id, start] of turnStart) if (start < end) kept.add(id);
  for (let i = 0; i < end; i++) {
    const e = entries[i];
    if (e.kind === "event" && e.event.type === "prompt_receipt" && e.event.status === "read") kept.add(e.event.promptId);
  }
  // Prompts that had not started by then (queued, or the edited one) are dropped.
  const copied = entries.slice(0, end).filter((e) => {
    const id = promptIdOf(e);
    return id === undefined || kept.has(id);
  });
  return { messageId: agentMessageId(entries[forkIndex]), entries: copied };
}
