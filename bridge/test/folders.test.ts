import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, expect, it } from "vitest";
import { createDirectory, PathGuard } from "../src/server/ext.js";
import { startTestBridge, TestClient, type TestBridge } from "./helpers.js";

let bridge: TestBridge | undefined;
let client: TestClient | undefined;
afterEach(async () => { client?.close(); await bridge?.stop(); client = undefined; bridge = undefined; });

it("creates a named child through paired ACP, lists it, and starts a session there", async () => {
  bridge = await startTestBridge();
  client = await TestClient.connect(bridge.url, bridge.tokenFor("folder-phone"));
  const created = await client.request("_codeaw/fs/mkdir", { path: bridge.home, name: "新的 專案" });
  expect(fs.statSync(created.path).isDirectory()).toBe(true);
  const list = await client.request("_codeaw/fs/list", { path: bridge.home });
  expect(list.entries.some((entry: any) => entry.path === created.path && entry.type === "dir")).toBe(true);
  const session = await client.request("session/new", { cwd: created.path, mcpServers: [] });
  expect(session.sessionId).toMatch(/^fake:/);
  await expect(client.request("_codeaw/fs/mkdir", { path: bridge.home, name: "新的 專案" })).rejects.toThrow(/已存在/);
});

it("rejects traversal, reserved names, missing parents and junction escapes", async () => {
  bridge = await startTestBridge();
  const guard = new PathGuard(() => [bridge!.home], () => []);
  for (const name of ["", ".", "..", "../escape", "child/nested", "child\\nested", "C:", "bad.", "bad ", "CON", "NUL.txt", "LPT1", " leading", "bad\0"]) {
    expect(() => createDirectory(guard, bridge!.home, name)).toThrow();
  }
  expect(() => createDirectory(guard, path.join(bridge!.home, "missing"), "child")).toThrow(/does not exist/);
  const link = path.join(bridge.home, "escape");
  fs.symlinkSync(path.dirname(bridge.home), link, process.platform === "win32" ? "junction" : "dir");
  expect(() => createDirectory(guard, link, "codeaw-must-not-create")).toThrow(/outside/);
  expect(fs.existsSync(path.join(bridge.home, "child"))).toBe(false);
});

it("honors the PC-only all-paths opt-in for other existing directories", async () => {
  bridge = await startTestBridge();
  client = await TestClient.connect(bridge.url, bridge.tokenFor("folder-phone"));
  const name = `codeaw-folder-${path.basename(bridge.home)}`;
  await expect(client.request("_codeaw/fs/mkdir", { path: os.tmpdir(), name })).rejects.toThrow(/outside/);
  bridge.loaded.config.filesystem.allowAllPaths = true;
  const created = await client.request("_codeaw/fs/mkdir", { path: os.tmpdir(), name });
  try { expect(fs.statSync(created.path).isDirectory()).toBe(true); }
  finally { fs.rmdirSync(created.path); }
});
