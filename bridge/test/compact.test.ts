import { describe, expect, it } from "vitest";
import { compactLog } from "../src/session/compact.js";
import type { LogEntry } from "../src/session/types.js";
import { desktopRecordChanges, projectDesktopConversation } from "../src/backend/codex-desktop-state.js";

function part(seq: number, content: unknown, codeaw: Record<string, unknown>): LogEntry {
  return { seq, t: seq, kind: "update", update: {
    sessionUpdate: "user_message_chunk", content,
    _meta: { codeaw: { mid: "u-prompt", promptId: "prompt", ...codeaw } },
  } } as LogEntry;
}

describe("user prompt replay", () => {
  it("rebuilds an edited native user input instead of treating it as a text suffix", () => {
    const project = (text: string) => projectDesktopConversation({ turns: [{
      turnId: "t", params: { clientUserMessageId: "p", input: [{ type: "text", text }] },
    }] }).records;
    const changes = desktopRecordChanges(project("original"), project("original edited"));
    expect(changes.reset).toBe(true);
    expect((changes.updates[0] as any).content.text).toBe("original edited");
  });
  it("retains text and image with distinct replacement part indexes", () => {
    const text = { type: "text", text: "Read this picture" };
    const image = { type: "image", data: "", uri: `codeaw-blob:${"a".repeat(64)}`, mimeType: "image/png" };
    const replay = compactLog([
      part(1, text, { replace: true, partIndex: 0, receipt: "read" }),
      part(2, image, { replace: true, partIndex: 1, receipt: "read" }),
    ]) as any[];
    expect(replay.map((e) => e.update.content)).toEqual([text, image]);
    expect(replay.map((e) => e.update._meta.codeaw.partIndex)).toEqual([0, 1]);
  });

  it("replaces earlier parts and retains the latest queued and steering flags", () => {
    const replay = compactLog([
      part(1, { type: "text", text: "old" }, { queued: true }),
      part(2, { type: "text", text: "replacement" }, { replace: true, partIndex: 0, receipt: "read", queued: false }),
      part(3, { type: "text", text: "" }, { steered: true }),
    ]) as any[];
    expect(replay).toHaveLength(1);
    expect(replay[0].update.content.text).toBe("replacement");
    expect(replay[0].update._meta.codeaw).toMatchObject({ queued: false, steered: true, receipt: "read", partIndex: 0 });
  });
});
