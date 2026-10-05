import { parentToolCallId } from "./subagent.js";
import { codeawMeta, type TurnState } from "./types.js";

export type WorkPhase = "thinking" | "command" | "tool" | "responding" | "attention" | "completed" | "cancelled" | "error" | "disconnected";
export interface WorkStatus { project: string; phase: WorkPhase; summary: string; updatedAt: number }

/** Only excerpts of summaries already emitted by the agent; never requests hidden reasoning. */
export function concise(text: unknown, limit = 180): string {
  const clean = String(text ?? "").replace(/\x1b\[[0-9;]*[A-Za-z]/g, "")
    .replace(/[\u0000-\u001f\u007f]/g, " ").replace(/[`*#]/g, "").replace(/\s+/g, " ").trim();
  const chars = [...clean];
  return chars.length > limit ? chars.slice(0, limit - 1).join("") + "…" : clean;
}

export function projectName(cwd: string): string {
  return concise(cwd.replace(/[\\/]+$/, "").split(/[\\/]/).pop() || cwd || "專案", 60);
}

interface Piece { nativeKey?: string; phase: WorkPhase; text: string; status?: string; order: number }

/** Bounded, independent of chat subscribers. Native replay keys retain turn identity. */
export class WorkTracker {
  private pieces = new Map<string, Piece>();
  private order = 0;
  reset(): void { this.pieces.clear(); }

  ingest(update: any): boolean {
    if (parentToolCallId(update)) return false;
    const type = update.sessionUpdate;
    if (["agent_thought_chunk", "agent_message_chunk"].includes(type) && update.content?.type === "text") {
      const nativeKey = update.messageId as string | undefined;
      const key = nativeKey ?? codeawMeta(update).mid ?? type;
      const old = this.pieces.get(key);
      // Keep a short tail while accumulating streamed chunks, then excerpt for the widget.
      const text = ((old?.text ?? "") + update.content.text).slice(-600);
      this.put(key, { nativeKey, phase: type === "agent_thought_chunk" ? "thinking" : "responding", text, order: ++this.order });
      return true;
    }
    if (type === "tool_call" || type === "tool_call_update") {
      const key = update.toolCallId;
      if (typeof key !== "string") return false;
      const old = this.pieces.get(key);
      const input = update.rawInput;
      const command = input?.command ?? input?.cmd;
      const kind = update.kind ?? (old?.phase === "command" ? "execute" : undefined);
      const text = command != null ? (Array.isArray(command) ? command.join(" ") : String(command)) : update.title ?? old?.text ?? "使用工具";
      this.put(key, { nativeKey: key, phase: kind === "execute" ? "command" : "tool", text,
        status: update.status ?? old?.status ?? "pending", order: ++this.order });
      return true;
    }
    return false;
  }

  private put(key: string, piece: Piece): void {
    this.pieces.delete(key);
    this.pieces.set(key, piece);
    if (this.pieces.size > 128) this.pieces.delete(this.pieces.keys().next().value!);
  }

  view(cwd: string, state: TurnState, nativeTurnId?: string, stopReason?: string): WorkStatus {
    const base = { project: projectName(cwd), updatedAt: Date.now() };
    if (state === "idle") {
      const phase = stopReason === "error" ? "error" : stopReason === "cancelled" ? "cancelled" : "completed";
      return { ...base, phase, summary: { error: "執行失敗", cancelled: "已停止", completed: "已完成" }[phase] };
    }
    if (state === "requires_action") return { ...base, phase: "attention", summary: "等待你的批准或回覆" };
    const pieces = [...this.pieces.values()].filter((p) => !nativeTurnId || p.nativeKey?.startsWith(nativeTurnId + ":"));
    const active = pieces.filter((p) => p.status && ["pending", "in_progress", "running"].includes(p.status));
    const latest = active.at(-1) ?? pieces.filter((p) => !p.status).at(-1);
    return { ...base, phase: latest?.phase ?? "thinking", summary: concise(latest?.text) || "正在思考…" };
  }
}
