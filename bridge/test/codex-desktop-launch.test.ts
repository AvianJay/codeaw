import { describe, expect, it } from "vitest";
import { CODEX_APP_ID, CodexDesktopLauncher, codexThreadUri, isLaunchableConversation, type DesktopLauncherOptions } from "../src/backend/codex-desktop-launcher.js";

const opened: string[] = [];

function launcher(options: DesktopLauncherOptions = {}) {
  opened.length = 0;
  return new CodexDesktopLauncher({ platform: "win32", open: (target) => { opened.push(target); return true; }, ...options });
}

describe("Codex Desktop automatic reopen", () => {
  it("opens the conversation URI for the chat that lost its owner", async () => {
    const l = launcher();
    expect(l.resume("01a10b8b-d98d-78b3-8bc8-f6fb346650a3")).toBe(true);
    await Promise.resolve();
    expect(opened).toEqual([codexThreadUri("01a10b8b-d98d-78b3-8bc8-f6fb346650a3")]);
    expect(opened[0]).toBe("codex://threads/01a10b8b-d98d-78b3-8bc8-f6fb346650a3");
  });

  it("falls back to launching the app itself when the deep link is not handled", async () => {
    opened.length = 0;
    const l = new CodexDesktopLauncher({
      platform: "win32",
      // The protocol handler is missing, so only the app shell target opens.
      open: (target) => { opened.push(target); return target.startsWith("shell:"); },
    });
    expect(l.resume("thread-1")).toBe(true);
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(opened).toEqual([codexThreadUri("thread-1"), `shell:AppsFolder\\${CODEX_APP_ID}`]);
  });

  it("never reopens the same chat twice inside the cooldown", () => {
    const l = launcher({ cooldownMs: 60000 });
    expect(l.resume("thread-1")).toBe(true);
    expect(l.resume("thread-1")).toBe(false);
    // A different chat is not blocked by the first chat's cooldown.
    expect(l.resume("thread-2")).toBe(true);
  });

  it("is inert off Windows, when disabled, and for unsafe identifiers", () => {
    expect(new CodexDesktopLauncher({ platform: "darwin", open: () => { throw new Error("must not open"); } }).resume("thread-1")).toBe(false);
    expect(new CodexDesktopLauncher({ platform: "win32", enabled: false, open: () => { throw new Error("must not open"); } }).resume("thread-1")).toBe(false);
    expect(new CodexDesktopLauncher({ platform: "win32", open: () => { throw new Error("must not open"); } }).resume("../evil path")).toBe(false);
    expect(isLaunchableConversation("01a10b8b-d98d-78b3-8bc8-f6fb346650a3")).toBe(true);
    expect(isLaunchableConversation("has space")).toBe(false);
    expect(isLaunchableConversation("")).toBe(false);
  });
});
