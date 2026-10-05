import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { createHash } from "node:crypto";
import { afterEach, expect, it } from "vitest";
import { PathGuard } from "../src/server/ext.js";
import { startTestBridge, TestClient, type TestBridge } from "./helpers.js";

let bridge: TestBridge | undefined;
let client: TestClient | undefined;
afterEach(async () => { client?.close(); await bridge?.stop(); client = undefined; bridge = undefined; });

it("uploads authenticated binary bytes into a known session and sends the attachment", async () => {
  bridge = await startTestBridge();
  const token = bridge.tokenFor("upload-phone");
  client = await TestClient.connect(bridge.url, token);
  const session = await client.request("session/new", { cwd: bridge.home, mcpServers: [] });
  const bytes = Buffer.from([0, 255, 128, 13, 10, 25]);
  const url = `${bridge.http}/api/uploads?sessionId=${encodeURIComponent(session.sessionId)}&name=${encodeURIComponent("中文.bin")}`;
  expect((await fetch(url, { method: "POST", body: bytes })).status).toBe(401);
  const response = await fetch(url, { method: "POST", headers: { Authorization: `Bearer ${token}` }, body: bytes });
  expect(response.status).toBe(201);
  const result = await response.json() as any;
  expect(fs.readFileSync(result.path)).toEqual(bytes);
  expect(result.sha256).toBe(createHash("sha256").update(bytes).digest("hex"));
  expect(result.block.uri).toMatch(/^file:/);
  await client.request("session/prompt", { sessionId: session.sessionId, prompt: [{ type: "text", text: "echo file" }, result.block] });
  expect(client.updates(session.sessionId).some((p) => p.update.content?.uri === result.block.uri)).toBe(true);
  expect((await fetch(url.replace(encodeURIComponent("中文.bin"), "..%2Fescape"), { method: "POST", headers: { Authorization: `Bearer ${token}` }, body: bytes })).status).toBe(400);
  expect((await fetch(url, { method: "POST", headers: { Authorization: `Bearer ${token}` }, body: Buffer.alloc(20 * 1024 * 1024 + 1) })).status).toBe(413);
});

it("requires opt-in for paths outside workspaces and rejects missing cwd before agent creation", async () => {
  bridge = await startTestBridge();
  client = await TestClient.connect(bridge.url, bridge.tokenFor("paths"));
  await expect(client.request("session/new", { cwd: path.dirname(bridge.home), mcpServers: [] })).rejects.toThrow(/outside/);
  await expect(client.request("session/new", { cwd: path.join(bridge.home, "missing"), mcpServers: [] })).rejects.toThrow(/does not exist/);
  bridge.loaded.config.filesystem.allowAllPaths = true;
  const roots = await client.request("_codeaw/workspaces/list", {});
  expect(roots.allowAllPaths).toBe(true);
  expect(roots.roots.some((root: any) => root.source === "filesystem")).toBe(true);
  await client.request("_codeaw/fs/list", { path: os.tmpdir() });
  const session = await client.request("session/new", { cwd: os.tmpdir(), mcpServers: [] });
  expect(session.sessionId).toMatch(/^fake:/);
});

it("resolves junctions before checking the allowed workspace", async () => {
  bridge = await startTestBridge();
  const guard = new PathGuard(() => [bridge!.home], () => []);
  const link = path.join(bridge.home, "escape-link");
  fs.symlinkSync(path.dirname(bridge.home), link, process.platform === "win32" ? "junction" : "dir");
  expect(() => guard.resolve(link)).toThrow(/outside/);
});

it("reports the opt-in even when filesystem roots are already configured workspaces", () => {
  const guard = new PathGuard(() => [path.parse(os.tmpdir()).root], () => [], () => true);
  expect(guard.allowsAllPaths).toBe(true);
  expect(guard.roots().find((root) => root.path === path.parse(os.tmpdir()).root)?.source).toBe("config");
});
