import fs from "node:fs";
import http from "node:http";
import net from "node:net";
import type { Duplex } from "node:stream";
import os from "node:os";
import { DeviceStore } from "../server/auth.js";
import { serveWeb } from "../server/web.js";
import { VERSION } from "../version.js";
import { tailscaleIPv4 } from "../util/tailscale.js";
import { DesktopManager } from "./manager.js";
import { NativeDesktop } from "./native.js";
import { GatewayManifest } from "./gateway-config.js";
import { BackendSocket } from "./backend-socket.js";

/** This entry imports no agent runtime or user configuration loader. */
export async function startDesktopGateway(manifest: GatewayManifest, overrides: {
  port?: number; hosts?: string[]; manager?: DesktopManager; connectBackend?: () => net.Socket;
} = {}) {
  const devices = new DeviceStore(manifest.home, true);
  const desktop = overrides.manager ?? new DesktopManager({ devices, enabled: () => manifest.enabled, systemAvailable: true,
    backendFactory: (privilege) => new NativeDesktop(privilege, manifest.helper, true), available: () => fs.existsSync(manifest.helper) });
  const servers = new Map<string, http.Server>(); const tunnels = new Set<Duplex>();
  const agent = new http.Agent({ keepAlive: false });
  agent.createConnection = () => overrides.connectBackend?.() ?? new BackendSocket(manifest) as unknown as net.Socket;
  let port = overrides.port ?? manifest.port;
  const unavailable = (res: http.ServerResponse) => {
    if (!res.headersSent) { res.writeHead(503, { "Content-Type": "application/json", "Cache-Control": "no-store" }); res.end(JSON.stringify({ error: "使用者 bridge 尚未啟動；遠端桌面仍可連線", code: "bridge_offline" })); }
    else res.destroy();
  };
  const request: http.RequestListener = (req, res) => {
    const url = new URL(req.url ?? "/", "http://localhost");
    void (async () => {
      if (await desktop.onRequest(req, res, url)) return;
      if (serveWeb(req, res, url.pathname, manifest.webRoot)) return;
      if (req.method === "GET" && url.pathname === "/api/health") {
        res.writeHead(200, { "Content-Type": "application/json", "Cache-Control": "no-store" });
        res.end(JSON.stringify({ ok: true, name: "codeaw-bridge", version: VERSION, host: os.hostname(), desktopGateway: true })); return;
      }
      if (req.method === "GET" && url.pathname === "/api/device") {
        const device = devices.authenticate(req.headers.authorization?.startsWith("Bearer ") ? req.headers.authorization.slice(7).trim() : undefined);
        res.writeHead(device ? 200 : 401, { "Content-Type": "application/json", "Cache-Control": "no-store" });
        res.end(JSON.stringify(device ? { deviceId: device.id } : { error: "Unauthorized" })); return;
      }
      // The user's backend pipe is ACL-restricted to that user and SYSTEM.
      const proxy = http.request({ method: req.method, path: req.url, headers: req.headers, agent }, (response) => {
        res.writeHead(response.statusCode ?? 502, response.headers); response.pipe(res);
      });
      proxy.on("error", () => unavailable(res)); req.on("aborted", () => proxy.destroy()); res.on("close", () => proxy.destroy()); req.pipe(proxy);
    })().catch(() => unavailable(res));
  };
  const upgrade = (req: http.IncomingMessage, socket: Duplex, head: Buffer) => {
    const url = new URL(req.url ?? "/", "http://localhost");
    if (desktop.onUpgrade(req, socket, head, url)) return;
    if (url.pathname !== "/acp") { socket.end("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n"); return; }
    const backend = overrides.connectBackend?.() ?? new BackendSocket(manifest);
    tunnels.add(socket); tunnels.add(backend);
    const clean = () => { tunnels.delete(socket); tunnels.delete(backend); socket.destroy(); backend.destroy(); };
    socket.on("error", clean); socket.on("close", clean); backend.on("close", clean);
    backend.on("error", () => { socket.end("HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n"); });
    backend.once("connect", () => {
      let headers = `${req.method} ${req.url} HTTP/1.1\r\n`;
      for (let i = 0; i < req.rawHeaders.length; i += 2) headers += `${req.rawHeaders[i]}: ${req.rawHeaders[i + 1]}\r\n`;
      backend.write(headers + "\r\n"); if (head.length) backend.write(head); socket.pipe(backend).pipe(socket);
    });
  };
  const wanted = () => overrides.hosts ?? (manifest.hosts === "auto" ? ["127.0.0.1", tailscaleIPv4()].filter((h): h is string => !!h) : manifest.hosts);
  const binding = new Set<string>(); let stopping = false;
  const listen = (host: string) => new Promise<void>((resolve, reject) => {
    binding.add(host); const server = http.createServer({ requestTimeout: 120_000 }, request); server.on("upgrade", upgrade);
    server.once("error", (e) => { binding.delete(host); reject(e); });
    server.listen(port, host, () => { binding.delete(host); port = (server.address() as net.AddressInfo).port; servers.set(host, server); resolve(); });
  });
  const close = async () => { stopping = true; clearInterval(retry); agent.destroy(); await desktop.dispose(); for (const socket of tunnels) socket.destroy();
    await Promise.all([...servers.values()].map((server) => new Promise<void>((resolve) => { server.closeAllConnections(); server.close(() => resolve()); }))); };
  const retry = setInterval(() => { if (!stopping) for (const host of wanted()) if (!servers.has(host) && !binding.has(host)) void listen(host).catch(() => undefined); }, 30_000); retry.unref();
  try { for (const host of wanted()) { try { await listen(host); } catch (e) { if (host === "127.0.0.1" || manifest.hosts !== "auto") throw e; } } }
  catch (e) { await close(); throw e; }
  return { port: () => port, close };
}
