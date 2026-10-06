import { describe, expect, it } from "vitest";
import { WorkTracker, concise, projectName } from "../src/session/work-status.js";

describe("Live Activity work summaries", () => {
  it("streams thoughts, prioritizes active commands, and folds tool completions", () => {
    const tracker = new WorkTracker();
    tracker.ingest({ sessionUpdate: "agent_thought_chunk", messageId: "turn:thought", content: { type: "text", text: "**檢查** " } });
    tracker.ingest({ sessionUpdate: "agent_thought_chunk", messageId: "turn:thought", content: { type: "text", text: "測試失敗原因" } });
    expect(tracker.view("D:\\proj\\Codeaw", "running", "turn")).toMatchObject({ project: "Codeaw", phase: "thinking", summary: "檢查 測試失敗原因" });
    tracker.ingest({ sessionUpdate: "tool_call", toolCallId: "turn:tool", title: "PowerShell", kind: "execute", status: "pending", rawInput: { command: ["pwsh", "-Command", "npm test"] } });
    tracker.ingest({ sessionUpdate: "tool_call_update", toolCallId: "turn:tool", status: "in_progress" });
    tracker.ingest({ sessionUpdate: "agent_message_chunk", messageId: "turn:reply", content: { type: "text", text: "正在跑測試" } });
    expect(tracker.view("/projects/app", "running", "turn")).toMatchObject({ phase: "command", summary: "pwsh -Command npm test" });
    tracker.ingest({ sessionUpdate: "tool_call_update", toolCallId: "turn:tool", status: "completed" });
    expect(tracker.view("/projects/app", "running", "turn").phase).toBe("responding");
    expect(tracker.view("/projects/app", "requires_action", "turn").phase).toBe("attention");
    expect(tracker.view("/projects/app", "idle", "turn", "cancelled").phase).toBe("cancelled");
    expect(tracker.view("/projects/app", "idle", "turn", "error").phase).toBe("error");
  });

  it("does not reuse old desktop turns, nested subagents, or previous ACP turn details", () => {
    const tracker = new WorkTracker();
    tracker.ingest({ sessionUpdate: "tool_call", toolCallId: "old:tool", title: "old command", kind: "execute" });
    expect(tracker.view("/p", "running", "new").summary).toBe("正在思考…");
    expect(tracker.ingest({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "child" }, _meta: { claudeCode: { parentToolUseId: "parent" } } })).toBe(false);
    tracker.reset();
    expect(tracker.view("/p", "running").phase).toBe("thinking");
    expect(tracker.view("/p", "running").summary).not.toContain("old");
  });

  it("bounds Unicode text and removes terminal / formatting control characters", () => {
    expect([...concise("😀".repeat(300))]).toHaveLength(180);
    expect(concise("\x1b[31m**test**\n`ok`\x1b[0m")).toBe("test ok");
    expect(projectName("C:\\")).toBe("C:");
    expect(projectName("/projects/中文專案/")).toBe("中文專案");
  });
});
