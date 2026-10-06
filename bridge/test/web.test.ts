import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { WebSocket } from "ws";
import { afterEach, describe, expect, it } from "vitest";
import { startTestBridge, type TestBridge } from "./helpers.js";

let tb: TestBridge | undefined;
let home: string | undefined;
afterEach(async () => {
  await tb?.stop();
  tb = undefined;
  if (home) fs.rmSync(home, { recursive: true, force: true });
  home = undefined;
});

async function fixture() {
  home = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-web-test-"));
  const web = path.join(home, "web");
  fs.mkdirSync(path.join(web, "assets"), { recursive: true });
  fs.writeFileSync(path.join(web, "index.html"), "<!doctype html><title>codeaw</title>");
  fs.writeFileSync(path.join(web, "main.dart.js"), "window.codeaw = true;");
  fs.writeFileSync(path.join(web, "canvaskit.wasm"), Buffer.from([0, 97, 115, 109]));
  fs.writeFileSync(path.join(web, ".hidden"), "private");
  fs.mkdirSync(path.join(home, "outside"));
  fs.writeFileSync(path.join(home, "outside/private.txt"), "private");
  fs.symlinkSync(path.join(home, "outside"), path.join(web, "assets/outside"), "junction");
  tb = await startTestBridge({ webRoot: web });
  return tb;
}

describe("bridge-hosted web app", () => {
  it("serves public browser assets, HEAD and SPA routes without a device token", async () => {
    const bridge = await fixture();
    for (const route of ["/", "/pair", "/session?id=fake:s1"]) {
      const res = await fetch(bridge.http + route);
      expect(res.status).toBe(200);
      expect(res.headers.get("content-type")).toContain("text/html");
      expect(res.headers.get("cache-control")).toBe("no-cache");
      expect(await res.text()).toContain("<title>codeaw</title>");
    }
    const js = await fetch(bridge.http + "/main.dart.js");
    expect(js.headers.get("content-type")).toContain("text/javascript");
    const wasm = await fetch(bridge.http + "/canvaskit.wasm");
    expect(wasm.headers.get("content-type")).toBe("application/wasm");
    const head = await fetch(bridge.http + "/main.dart.js", { method: "HEAD" });
    expect(head.status).toBe(200);
    expect(Number(head.headers.get("content-length"))).toBeGreaterThan(0);
    expect(await head.text()).toBe("");
    for (const route of ["/missing.js", "/assets/missing", "/.hidden", "/assets/outside/private.txt", "/%2e%2e%2foutside/private.txt"]) {
      expect((await fetch(bridge.http + route)).status, route).toBe(404);
    }
  });

  it("revalidates unchanged assets and gzips large text and wasm for browsers that accept it", async () => {
    const bridge = await fixture();
    const big = "window.codeaw = { assets: true };\n".repeat(4000);
    fs.writeFileSync(path.join(home!, "web", "main.dart.js"), big);
    const plain = await fetch(bridge.http + "/main.dart.js", { headers: { "Accept-Encoding": "identity" } });
    expect(plain.headers.get("content-encoding")).toBeNull();
    expect(Number(plain.headers.get("content-length"))).toBe(Buffer.byteLength(big));
    const tag = plain.headers.get("etag")!;
    expect(tag).toMatch(/^W\/".+"$/);
    expect(await plain.text()).toBe(big);

    const http = await import("node:http");
    const gzipped = await new Promise<{ status?: number; headers: Record<string, unknown>; body: Buffer }>((resolve, reject) => {
      http.get(bridge.http + "/main.dart.js", { headers: { "Accept-Encoding": "gzip, deflate, br" } }, (res) => {
        const chunks: Buffer[] = [];
        res.on("data", (c: Buffer) => chunks.push(c));
        res.on("end", () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks) }));
      }).on("error", reject);
    });
    expect(gzipped.status).toBe(200);
    expect(gzipped.headers["content-encoding"]).toBe("gzip");
    expect(gzipped.headers.vary).toBe("Accept-Encoding");
    expect(gzipped.body.length).toBeLessThan(Buffer.byteLength(big) / 20);
    expect((await import("node:zlib")).gunzipSync(gzipped.body).toString()).toBe(big);

    const revalidated = await fetch(bridge.http + "/main.dart.js", { headers: { "If-None-Match": tag } });
    expect(revalidated.status).toBe(304);
    expect(await revalidated.text()).toBe("");
    // Small files are not worth compressing.
    const index = await fetch(bridge.http + "/", { headers: { "Accept-Encoding": "gzip" } });
    expect(index.headers.get("content-encoding")).toBeNull();
  });

  it("keeps APIs private and supports browser query authentication after pairing", async () => {
    const bridge = await fixture();
    expect((await fetch(bridge.http + "/api/fs/raw?path=x")).status).toBe(401);
    expect((await fetch(bridge.http + "/api/unknown")).status).toBe(401);
    expect((await fetch(bridge.http + "/acp")).status).toBe(401);
    expect((await fetch(bridge.http + "/api/device")).status).toBe(401);
    const code = bridge.bridge.devices.createPairingCode();
    const res = await fetch(bridge.http + "/api/pair", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code, deviceName: "Browser" }),
    });
    expect(res.status).toBe(200);
    const { token, deviceId } = await res.json() as { token: string; deviceId: string };
    const check = await fetch(bridge.http + "/api/device", { headers: { Authorization: `Bearer ${token}` } });
    expect(check.status).toBe(200);
    expect(await check.json()).toEqual({ deviceId });
    const ws = new WebSocket(`${bridge.url}?token=${token}`);
    try {
      const initialized = new Promise<any>((resolve, reject) => {
        ws.once("error", reject);
        ws.on("message", (data) => {
          const message = JSON.parse(data.toString());
          if (message.id === 1) resolve(message);
        });
        ws.once("open", () => ws.send(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: 1, clientCapabilities: {} } })));
      });
      expect((await initialized).result.agentInfo.name).toBe("codeaw-bridge");
      expect(ws.extensions).toContain("permessage-deflate");
      const file = path.join(bridge.home, "browser.txt");
      fs.writeFileSync(file, "browser file");
      const raw = await fetch(`${bridge.http}/api/fs/raw?${new URLSearchParams({ path: file, token })}`);
      expect(raw.status).toBe(200);
      expect(await raw.text()).toBe("browser file");
    } finally { ws.terminate(); }
    bridge.bridge.devices.revoke(deviceId);
    expect((await fetch(bridge.http + "/api/device", { headers: { Authorization: `Bearer ${token}` } })).status).toBe(401);
  });
});
