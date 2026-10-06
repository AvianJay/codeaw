import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import http from "node:http";
import { once } from "node:events";
import { createHash } from "node:crypto";
import { afterEach, expect, it, vi } from "vitest";
import { PathGuard } from "../src/server/ext.js";
import { startTestBridge, TestClient, type TestBridge } from "./helpers.js";
import { MAX_UPLOAD_BYTES } from "../src/server/uploads.js";

let bridge: TestBridge | undefined;
let client: TestClient | undefined;
afterEach(async () => { vi.restoreAllMocks(); client?.close(); await bridge?.stop(); client = undefined; bridge = undefined; });

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
  const rejected = http.request(url, { method: "POST", headers: { Authorization: `Bearer ${token}`, "Content-Length": MAX_UPLOAD_BYTES + 1 } });
  rejected.end();
  const [oversized] = await once(rejected, "response") as [http.IncomingMessage];
  expect(oversized.statusCode).toBe(413);
  oversized.resume();
});

it("streams a file larger than the old limit to disk and removes an interrupted upload", async () => {
  bridge = await startTestBridge();
  const token = bridge.tokenFor("large-upload-phone");
  client = await TestClient.connect(bridge.url, token);
  const session = await client.request("session/new", { cwd: bridge.home, mcpServers: [] });
  const url = `${bridge.http}/api/uploads?sessionId=${encodeURIComponent(session.sessionId)}&name=large.bin`;
  const chunk = Buffer.alloc(64 * 1024, 0xab);
  const count = 384; // 24 MiB, beyond the former 20 MiB cap.
  const hash = createHash("sha256");
  const upload = http.request(url, { method: "POST", headers: { Authorization: `Bearer ${token}`, "Content-Length": chunk.length * count } });
  const response = once(upload, "response") as Promise<[http.IncomingMessage]>;
  for (let i = 0; i < count; i++) {
    hash.update(chunk);
    if (!upload.write(chunk)) await once(upload, "drain");
  }
  upload.end();
  const [received] = await response;
  expect(received.statusCode).toBe(201);
  let body = "";
  for await (const data of received) body += data;
  const result = JSON.parse(body);
  expect(result.size).toBe(chunk.length * count);
  expect(fs.statSync(result.path).size).toBe(result.size);
  expect(result.sha256).toBe(hash.digest("hex"));
  const storedHash = createHash("sha256");
  for await (const data of fs.createReadStream(result.path)) storedHash.update(data);
  expect(storedHash.digest("hex")).toBe(result.sha256);

  const broken = http.request(url, { method: "POST", headers: { Authorization: `Bearer ${token}`, "Content-Length": chunk.length * 10 } });
  broken.on("error", () => {});
  broken.write(chunk);
  const folder = path.join(bridge.home, ".codeaw-uploads");
  for (let i = 0; i < 100 && fs.readdirSync(folder).length < 2; i++) await new Promise((resolve) => setTimeout(resolve, 10));
  expect(fs.readdirSync(folder)).toHaveLength(2);
  broken.destroy();
  for (let i = 0; i < 100 && fs.readdirSync(folder).length > 1; i++) await new Promise((resolve) => setTimeout(resolve, 10));
  expect(fs.readdirSync(folder)).toEqual([path.basename(result.path)]);
});

it("preserves the bridge-scoped upload response without falling back for an invalid session", async () => {
  bridge = await startTestBridge();
  const token = bridge.tokenFor("compat-upload-phone");
  const chunk = Buffer.alloc(64 * 1024, 0x75);
  const url = `${bridge.http}/api/uploads?name=compat.txt`;
  const request = http.request(url, { method: "POST", headers: { Authorization: `Bearer ${token}`, "Content-Type": "text/plain" } });
  const response = once(request, "response") as Promise<[http.IncomingMessage]>;
  for (let i = 0; i < 384; i++) if (!request.write(chunk)) await once(request, "drain");
  request.end();
  const [received] = await response;
  expect(received.statusCode).toBe(200);
  let body = "";
  for await (const data of received) body += data;
  const file = JSON.parse(body);
  expect(file).toMatchObject({ name: "compat.txt", size: 24 * 1024 * 1024, mimeType: "text/plain" });
  expect(file.uri).toMatch(/^file:/);
  expect(fs.statSync(file.path).size).toBe(file.size);
  client = await TestClient.connect(bridge.url, token);
  expect((await client.request("_codeaw/fs/read", { path: file.path, maxBytes: 100 })).size).toBe(file.size);
  const invalid = await fetch(`${url}&sessionId=missing:unknown`, { method: "POST", headers: { Authorization: `Bearer ${token}` }, body: "no fallback" });
  expect(invalid.status).toBe(400);
});

for (const scoped of [true, false]) {
  it(`returns a disk error while the request is still sending and stays alive (${scoped ? "session" : "bridge"})`, async () => {
    bridge = await startTestBridge();
    const token = bridge.tokenFor("disk-error-phone");
    client = await TestClient.connect(bridge.url, token);
    const session = await client.request("session/new", { cwd: bridge.home, mcpServers: [] });
    const url = `${bridge.http}/api/uploads?name=disk-error.bin${scoped ? `&sessionId=${encodeURIComponent(session.sessionId)}` : ""}`;
    const realOpen = fs.promises.open;
    vi.spyOn(fs.promises, "open").mockImplementationOnce(async (...args) => {
      const handle = await realOpen(...args);
      vi.spyOn(handle, "write").mockImplementationOnce(async () => {
        await new Promise((resolve) => setTimeout(resolve, 20));
        throw Object.assign(new Error("disk full"), { code: "ENOSPC" });
      });
      return handle;
    });
    const request = http.request(url, { method: "POST", headers: { Authorization: `Bearer ${token}` } });
    request.on("error", () => {});
    const response = once(request, "response") as Promise<[http.IncomingMessage]>;
    request.write(Buffer.alloc(1024)); // Keep the sender open when the asynchronous write fails.
    const [received] = await response;
    expect(received.statusCode).toBe(500);
    received.resume();
    request.end();
    const folder = scoped ? path.join(bridge.home, ".codeaw-uploads") : path.join(bridge.loaded.dataDir, "uploads");
    expect(fs.readdirSync(folder)).toEqual([]);
    expect((await fetch(`${bridge.http}/api/health`)).status).toBe(200);
    await expect(client.request("_codeaw/activity/list", {})).resolves.toBeDefined();
  });
}

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
