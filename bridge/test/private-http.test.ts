import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import http from "node:http";
import net from "node:net";
import { WebSocket, WebSocketServer } from "ws";
import { afterEach, expect, it } from "vitest";
import { listenPrivateHttp } from "../src/remote-desktop/private-http.js";

const cleanup: (() => Promise<void>)[] = [];
afterEach(async () => { for (const close of cleanup.splice(0).reverse()) await close(); });

it("relays streamed HTTP and WebSocket traffic through a private pipe while rejecting direct TCP requests", async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-pipe-relay-"));
  cleanup.push(async () => { fs.rmSync(directory, { recursive: true, force: true }); });
  const pipe = process.platform === "win32" ? `\\\\.\\pipe\\codeaw-backend-${crypto.randomBytes(16).toString("hex")}` : path.join(directory, "http.sock");
  const wss = new WebSocketServer({ noServer: true });
  let requests = 0;
  const listener = await listenPrivateHttp(pipe, (req, res) => {
    requests++;
    expect(req.headers["x-codeaw-backend-nonce"]).toBeUndefined();
    req.pipe(res);
  }, (req, socket, head) => wss.handleUpgrade(req, socket, head, (ws) => ws.on("message", (value) => ws.send(value))), async () => {}, true);
  cleanup.push(async () => { for (const client of wss.clients) client.terminate(); listener.closeAllConnections(); await new Promise<void>((resolve) => listener.close(resolve)); });
  const payload = crypto.randomBytes(2 * 1024 * 1024);
  const echoed = await new Promise<Buffer>((resolve, reject) => {
    const req = http.request({ socketPath: pipe, path: "/echo", method: "POST", headers: { "x-codeaw-backend-nonce": "spoof" } }, (res) => {
      const chunks: Buffer[] = []; res.on("data", (chunk) => chunks.push(chunk)); res.on("end", () => resolve(Buffer.concat(chunks))); res.on("error", reject);
    });
    req.on("error", reject); req.write(payload.subarray(0, 1000)); req.end(payload.subarray(1000));
  });
  expect(echoed).toEqual(payload);
  for (const nonce of ["spoof", "é".repeat(64)]) {
    await expect(new Promise<void>((resolve, reject) => {
      const req = http.get({ host: "127.0.0.1", port: listener.tcpPort, path: "/echo", headers: { "x-codeaw-backend-nonce": nonce } }, () => resolve());
      req.on("error", reject);
    })).rejects.toThrow();
  }
  expect(requests).toBe(1);
  const ws = new WebSocket("ws://localhost/echo", { createConnection: () => net.connect(pipe) });
  await new Promise<void>((resolve, reject) => { ws.once("open", resolve); ws.once("error", reject); });
  const reply = new Promise<Buffer>((resolve) => ws.once("message", (value) => resolve(value as Buffer)));
  ws.send("synthetic-websocket");
  expect((await reply).toString()).toBe("synthetic-websocket");
  ws.close();
});
