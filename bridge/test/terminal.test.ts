import fs from "node:fs";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { startTestBridge, TestClient, type TestBridge } from "./helpers.js";

let tb: TestBridge | undefined;
const clients: TestClient[] = [];
afterEach(async () => {
  for (const c of clients.splice(0)) c.close();
  await tb?.stop();
  tb = undefined;
});

async function connect(name = "phone") {
  const c = await TestClient.connect(tb!.url, tb!.tokenFor(name));
  clients.push(c);
  return c;
}

function output(c: TestClient, id: string) {
  return c.received.filter((e) => e.method === "_codeaw/terminal/event" && e.params.terminalId === id && e.params.type === "data")
    .map((e) => e.params.data).join("");
}

describe("interactive terminals", () => {
  it("restores independent terminals in the same folder after disconnect, including the selected tab", async () => {
    tb = await startTestBridge();
    const a = await connect();
    const first = await a.request("_codeaw/terminal/open", { cwd: tb.home, createNew: true });
    const second = await a.request("_codeaw/terminal/open", { cwd: tb.home, createNew: true });
    expect(second.terminalId).not.toBe(first.terminalId);
    await a.waitFor(() => [first, second].every((t) => process.platform === "win32" ? output(a, t.terminalId).includes("> ") : output(a, t.terminalId).length > 0));
    for (const [t, value] of [[first, "one"], [second, "two"]] as const) {
      await a.request("_codeaw/terminal/write", {
        terminalId: t.terminalId,
        data: process.platform === "win32" ? `$terminalValue = '${value}'; Write-Output ('ready-' + $terminalValue)\r` : `terminalValue=${value}; printf 'ready-%s\\n' "$terminalValue"\r`,
      });
      await a.waitFor(() => output(a, t.terminalId).includes(`ready-${value}`));
    }
    await a.request("_codeaw/terminal/detach", { terminalId: second.terminalId });
    a.close();
    const b = await connect();
    const saved = await b.request("_codeaw/terminal/list", {});
    expect(saved.terminals.map((t: any) => t.terminalId)).toEqual([first.terminalId, second.terminalId]);
    expect(saved.activeTerminalId).toBe(second.terminalId);
    expect(saved.maxTerminals).toBe(8);
    const other = await connect("other-device");
    expect((await other.request("_codeaw/terminal/list", {})).terminals).toEqual([]);
    for (const [t, value] of [[first, "one"], [second, "two"]] as const) {
      const replay = await b.request("_codeaw/terminal/open", { terminalId: t.terminalId });
      expect(replay.events.map((e: any) => e.data ?? "").join("")).toContain(`ready-${value}`);
      await b.request("_codeaw/terminal/write", {
        terminalId: t.terminalId,
        data: process.platform === "win32" ? "Write-Output ('restored-' + $terminalValue)\r" : "printf 'restored-%s\\n' \"$terminalValue\"\r",
      });
      await b.waitFor(() => output(b, t.terminalId).includes(`restored-${value}`));
    }
    await b.request("_codeaw/terminal/close", { terminalId: second.terminalId });
    const remaining = await b.request("_codeaw/terminal/list", {});
    expect(remaining.terminals.map((t: any) => t.terminalId)).toEqual([first.terminalId]);
    expect(remaining.activeTerminalId).toBe(first.terminalId);
  }, 25_000);

  it.runIf(process.platform === "win32")("executes iOS LF and multiline paste in PowerShell instead of entering continuation mode", async () => {
    tb = await startTestBridge();
    const c = await connect();
    const t = await c.request("_codeaw/terminal/open", { cwd: tb.home });
    await c.waitFor(() => output(c, t.terminalId).includes("> "));
    fs.mkdirSync(path.join(tb.home, "nested"));
    await c.request("_codeaw/terminal/write", { terminalId: t.terminalId, data: "cd nested\nWrite-Output ('LF-' + '中文')\n(Get-Location).Path\n" });
    await c.waitFor(() => output(c, t.terminalId).includes("LF-中文") && output(c, t.terminalId).includes(path.join(tb!.home, "nested")));
    await c.request("_codeaw/terminal/write", { terminalId: t.terminalId, data: "Get-ChildItem\n" });
    await c.request("_codeaw/terminal/close", { terminalId: t.terminalId });
  }, 15000);
  it("streams a real shell, keeps its working directory, and replays after reconnect", async () => {
    tb = await startTestBridge();
    const a = await connect();
    const opened = await a.request("_codeaw/terminal/open", { cwd: tb.home, cols: 80, rows: 24 });
    const id = opened.terminalId;
    await a.waitFor(() => process.platform === "win32" ? output(a, id).includes("> ") : output(a, id).length > 0);
    await a.request("_codeaw/terminal/write", { terminalId: id, data: process.platform === "win32" ? "Write-Output ('hello-' + 'terminal')\r" : "printf 'hello-%s\\n' terminal\r" });
    await a.waitFor(() => output(a, id).includes("hello-terminal"));
    fs.mkdirSync(path.join(tb.home, "nested"));
    await a.request("_codeaw/terminal/write", { terminalId: id, data: "cd nested\r" });
    await a.request("_codeaw/terminal/write", { terminalId: id, data: process.platform === "win32" ? "(Get-Location).Path\r" : "pwd\r" });
    await a.waitFor(() => output(a, id).includes(path.join(tb!.home, "nested")));
    const seq = Math.max(...a.received.filter((e) => e.params.terminalId === id).map((e) => e.params.seq));
    a.close();

    const b = await connect();
    const resumed = await b.request("_codeaw/terminal/open", { terminalId: id, afterSeq: seq, cols: 100, rows: 30 });
    expect(resumed.terminalId).toBe(id);
    expect(resumed.full).toBe(false);
    expect(resumed.events.every((e: any) => e.seq > seq)).toBe(true);
    await b.request("_codeaw/terminal/write", { terminalId: id, data: process.platform === "win32" ? "(Get-Location).Path\r" : "pwd\r" });
    await b.waitFor(() => output(b, id).includes(path.join(tb!.home, "nested")));
    await b.request("_codeaw/terminal/write", { terminalId: id, data: "exit 7\r" });
    await b.waitFor(() => b.received.some((e) => e.params.terminalId === id && e.params.type === "exit"));
    expect(b.received.find((e) => e.params.terminalId === id && e.params.type === "exit")!.params.exitCode).toBe(7);
    await expect(b.request("_codeaw/terminal/write", { terminalId: id, data: "whoami\r" })).rejects.toThrow(/exited/);
  }, 25_000);

  it("rejects other devices, invalid dimensions, and starting paths outside workspaces", async () => {
    tb = await startTestBridge();
    const a = await connect("A");
    const b = await connect("B");
    await expect(a.request("_codeaw/terminal/open", { cwd: path.dirname(tb.home) })).rejects.toThrow(/outside/);
    await expect(a.request("_codeaw/terminal/open", { cwd: tb.home, cols: -1 })).rejects.toThrow(/dimensions/);
    const s = await a.request("_codeaw/terminal/open", { cwd: tb.home });
    for (const method of ["open", "write", "resize", "close", "detach"]) {
      await expect(b.request(`_codeaw/terminal/${method}`, { terminalId: s.terminalId, data: "exit\r", cols: 80, rows: 24 })).rejects.toThrow(/not found/);
    }
    expect(b.received.some((e) => e.method === "_codeaw/terminal/event")).toBe(false);
    await a.request("_codeaw/terminal/close", { terminalId: s.terminalId });
    await expect(a.request("_codeaw/terminal/open", { terminalId: s.terminalId })).rejects.toThrow(/not found/);
  });

  it("reuses a device's shell on returning to the same folder and replays detached output", async () => {
    tb = await startTestBridge();
    const c = await connect();
    const first = await c.request("_codeaw/terminal/open", { cwd: tb.home });
    await c.waitFor(() => process.platform === "win32" ? output(c, first.terminalId).includes("> ") : output(c, first.terminalId).length > 0);
    await c.request("_codeaw/terminal/detach", { terminalId: first.terminalId });
    // Writes are independent of viewing: output produced while detached must be retained.
    await c.request("_codeaw/terminal/write", {
      terminalId: first.terminalId,
      data: process.platform === "win32" ? "Write-Output ('detached-' + 'output')\r" : "printf 'detached-%s\\n' output\r",
    });
    let second: any;
    for (let i = 0; i < 100; i++) {
      second = await c.request("_codeaw/terminal/open", { cwd: tb.home });
      if (second.events.map((e: any) => e.data ?? "").join("").includes("detached-output")) break;
      await c.request("_codeaw/terminal/detach", { terminalId: first.terminalId });
      await new Promise((r) => setTimeout(r, 20));
    }
    expect(second.terminalId).toBe(first.terminalId);
    expect(second.events.some((e: any) => e.data?.includes("detached-output"))).toBe(true);
    await c.request("_codeaw/terminal/close", { terminalId: first.terminalId });
    const replacement = await c.request("_codeaw/terminal/open", { cwd: tb.home });
    expect(replacement.terminalId).not.toBe(first.terminalId);
  });
});
