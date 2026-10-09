import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import net from "node:net";
import http from "node:http";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { WebSocket, WebSocketServer } from "ws";
import { listenPrivateHttp } from "../src/remote-desktop/private-http.js";
import { startDesktopGateway } from "../src/remote-desktop/gateway.js";
import { desktopHelper } from "../src/remote-desktop/native.js";

if (process.platform !== "win32") throw new Error("This smoke test checks Windows pipe ownership");
const directory = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-private-http-smoke-"));
const helper = process.argv[2] ?? desktopHelper(); if (!helper || !fs.existsSync(helper)) throw new Error("Desktop helper missing");
const execute = promisify(execFile);
const sid = (await execute("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", "[Security.Principal.WindowsIdentity]::GetCurrent().User.Value"], { windowsHide: true })).stdout.trim();
const pipe = `\\\\.\\pipe\\codeaw-backend-${crypto.randomBytes(16).toString("hex")}`;
const wss = new WebSocketServer({ noServer: true });
const listener = await listenPrivateHttp(pipe, (req, res) => {
  if (req.headers["x-codeaw-backend-nonce"] || req.headers.authorization !== "Bearer synthetic-pipe-token") { res.destroy(); return; }
  req.pipe(res);
}, (req, socket, head) => wss.handleUpgrade(req, socket, head, (ws) => ws.on("message", (value) => ws.send(value))),
async () => { await execute(helper, ["--protect-pipe", pipe, sid], { windowsHide: true, timeout: 10000 }); });
const gateway = await startDesktopGateway({ name: "CodeawDesktop-0123456789abcdef", configFile: path.join(directory, "unused.yaml"), home: directory,
  ownerSid: sid, backendPipe: pipe, port: 7860, hosts: ["127.0.0.1"], gateway: "unused", helper, webRoot: "unused", enabled: false }, { port: 0, hosts: ["127.0.0.1"] });
try {
  const payload = crypto.randomBytes(2 * 1024 * 1024);
  const response = await fetch(`http://127.0.0.1:${gateway.port()}/api/synthetic-pipe`, { method: "POST", headers: { Authorization: "Bearer synthetic-pipe-token" }, body: payload, signal: AbortSignal.timeout(10000) });
  if (response.status !== 200 || !Buffer.from(await response.arrayBuffer()).equals(payload)) throw new Error("Gateway HTTP relay failed");
  if (listener.tcpPort) {
    let rejected = false;
    try { await fetch(`http://127.0.0.1:${listener.tcpPort}/api/synthetic-pipe`, { headers: { Authorization: "Bearer synthetic-pipe-token" }, signal: AbortSignal.timeout(2000) }); }
    catch { rejected = true; }
    if (!rejected) throw new Error("Unauthenticated loopback access was accepted");
  }
  const ws = new WebSocket(`ws://127.0.0.1:${gateway.port()}/acp`, { handshakeTimeout: 10000 });
  await new Promise<void>((resolve, reject) => { ws.once("open", resolve); ws.once("error", reject); });
  const reply = new Promise<Buffer>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("WebSocket relay timed out")), 10000);
    ws.once("message", (value) => { clearTimeout(timer); resolve(value as Buffer); });
  });
  ws.send("synthetic-websocket");
  if ((await reply).toString() !== "synthetic-websocket") throw new Error("Gateway WebSocket relay failed");
  ws.close();
  process.stdout.write(`Windows private HTTP and WebSocket relay passed (${process.versions.bun ? "Bun" : "Node"}); pipe owner and loopback access verified\n`);
} finally {
  for (const client of wss.clients) client.terminate();
  await gateway.close(); listener.closeAllConnections();
  await new Promise<void>((resolve) => listener.close(resolve));
  fs.rmSync(directory, { recursive: true, force: true });
}
