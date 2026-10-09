import fs from "node:fs";
import http from "node:http";
import type { Duplex } from "node:stream";
import { WebSocketServer, type WebSocket } from "ws";
import { AcpServer } from "@agentclientprotocol/sdk/experimental/server";
import * as acp from "@agentclientprotocol/sdk";
import { logger } from "../util/log.js";
import { VERSION } from "../version.js";
import type { DeviceStore } from "./auth.js";
import { mimeFor, type PathGuard } from "./ext.js";
import { FrontendConnection, type FrontendDeps } from "./frontend.js";
import { enableGzipFrames } from "./compression.js";
import type { SessionStore } from "../session/store.js";
import { receiveUpload, UploadError, UploadTooLargeError, type UploadStore } from "./uploads.js";
import { findWebRoot, serveWeb } from "./web.js";
import path from "node:path";
import { pipeline } from "node:stream/promises";
import { attachmentHeader, DownloadError, sendArchive } from "./downloads.js";

const log = logger("http");
const HEARTBEAT_MS = 20_000;
const MAX_PAIR_BODY = 4096;

export interface HttpDeps extends FrontendDeps {
  devices: DeviceStore;
  store: SessionStore;
  uploads: UploadStore;
  hostName: string;
  webRoot?: string;
}

function bearer(req: http.IncomingMessage, url: URL): string | undefined {
  const h = req.headers.authorization;
  if (h?.startsWith("Bearer ")) return h.slice(7).trim();
  return url.searchParams.get("token") ?? undefined;
}

function sendJson(res: http.ServerResponse, status: number, body: unknown): void {
  const data = JSON.stringify(body);
  res.writeHead(status, { "Content-Type": "application/json; charset=utf-8", "Content-Length": Buffer.byteLength(data), "Cache-Control": "no-store" });
  res.end(data);
}

function readBody(req: http.IncomingMessage, limit: number): Promise<string> {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks: Buffer[] = [];
    req.on("data", (c: Buffer) => {
      size += c.length;
      if (size > limit) {
        reject(new Error("body too large"));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

function sendFile(res: http.ServerResponse, file: string, mimeType: string): void {
  const st = fs.statSync(file);
  res.writeHead(200, { "Content-Type": mimeType, "Content-Length": st.size, "Cache-Control": "private, max-age=31536000, immutable" });
  fs.createReadStream(file).pipe(res);
}

/**
 * HTTP server: REST helpers + the `/acp` WebSocket endpoint. Each upgrade gets its own
 * ACP AgentApp bound to the authenticated device.
 */
export interface HttpHandlers {
  onRequest: http.RequestListener;
  onUpgrade: (req: http.IncomingMessage, socket: Duplex, head: Buffer) => void;
  close: () => Promise<void>;
}

export function createHttpHandlers(deps: HttpDeps): HttpHandlers {
  const webRoot = deps.webRoot ?? findWebRoot();
  const acpServer = new AcpServer({
    // Every connection supplies its own agent in prepareWebSocketUpgrade(); this is never used.
    createAgent: () => acp.agent({ name: "codeaw-unbound" }),
  });
  const wss = new WebSocketServer({ noServer: true, maxPayload: 64 * 1024 * 1024,
    perMessageDeflate: {
      serverNoContextTakeover: true, clientNoContextTakeover: true,
      concurrencyLimit: 4, threshold: 1024,
      zlibDeflateOptions: { level: 3, memLevel: 7 },
    },
  });
  const sockets = new Set<WebSocket>();

  const onRequest: http.RequestListener = async (req, res) => {
    const url = new URL(req.url ?? "/", "http://localhost");
    try {
      if (serveWeb(req, res, url.pathname, webRoot)) return;
      if (["GET", "HEAD"].includes(req.method ?? "") && !/^\/(api|acp)(\/|$)/.test(url.pathname)) {
        return sendJson(res, 404, { error: "Web app not found. Run npm run build:web in bridge, or install a release with its web folder." });
      }
      if (req.method === "GET" && url.pathname === "/api/health") {
        return sendJson(res, 200, { ok: true, name: "codeaw-bridge", version: VERSION, host: deps.hostName });
      }
      if (req.method === "POST" && url.pathname === "/api/pair") {
        let body: any;
        try {
          body = JSON.parse(await readBody(req, MAX_PAIR_BODY));
        } catch {
          return sendJson(res, 400, { error: "Invalid JSON body" });
        }
        const result = deps.devices.pair(String(body?.code ?? ""), String(body?.deviceName ?? "device"));
        if ("error" in result) return sendJson(res, result.status, { error: result.error });
        log.info(`paired new device "${result.device.name}" (${result.device.id})`);
        return sendJson(res, 200, {
          deviceId: result.device.id,
          token: result.token,
          bridge: { name: deps.hostName, version: VERSION },
        });
      }
      const device = deps.devices.authenticate(bearer(req, url));
      if (!device) return sendJson(res, 401, { error: "Unauthorized" });

      if (req.method === "GET" && url.pathname === "/api/device") {
        return sendJson(res, 200, { deviceId: device.id });
      }

      const blob = url.pathname.match(/^\/api\/blobs\/([0-9a-f]{64})$/);
      if (req.method === "GET" && blob) {
        const found = deps.store.blob(blob[1]);
        if (!found) return sendJson(res, 404, { error: "Not found" });
        return sendFile(res, found.file, found.mimeType);
      }
      if (req.method === "GET" && url.pathname === "/api/fs/raw") {
        let file: string;
        try {
          file = deps.guard.resolveReadable(url.searchParams.get("path"));
        } catch (err) {
          return sendJson(res, 403, { error: (err as Error).message });
        }
        if (!fs.existsSync(file) || !fs.statSync(file).isFile()) return sendJson(res, 404, { error: "Not found" });
        if (url.searchParams.get("download") === "1") {
          const source = fs.createReadStream(file);
          res.writeHead(200, { "Content-Type": mimeFor(file) ?? "application/octet-stream", "Content-Length": fs.statSync(file).size,
            "Content-Disposition": attachmentHeader(path.basename(file)), "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" });
          await pipeline(source, res);
          return;
        }
        return sendFile(res, file, mimeFor(file) ?? "application/octet-stream");
      }
      if (req.method === "POST" && url.pathname === "/api/fs/archive") {
        let body: unknown;
        try { body = JSON.parse(await readBody(req, 64 * 1024)); }
        catch { return sendJson(res, 400, { error: "Invalid or oversized archive request" }); }
        try { await sendArchive(res, deps.guard, body); }
        catch (error) {
          if (error instanceof DownloadError && !res.headersSent) return sendJson(res, error.status, { error: error.message });
          if (!res.destroyed) throw error;
        }
        return;
      }
      if (req.method === "POST" && url.pathname === "/api/uploads") {
        if (url.searchParams.has("sessionId")) {
          try {
            const cwd = deps.guard.directory(deps.manager.uploadCwd(url.searchParams.get("sessionId")));
            return sendJson(res, 201, await receiveUpload(req, cwd, url.searchParams.get("name")));
          } catch (error) {
            req.resume();
            if (error instanceof UploadError) return sendJson(res, error.status, { error: error.message });
            if (error instanceof acp.RequestError) return sendJson(res, 400, { error: error.message });
            throw error;
          }
        }
        const tooLarge = () => {
          sendJson(res, 413, { error: new UploadTooLargeError(deps.uploads.limit).message });
          req.resume();
        };
        if (Number(req.headers["content-length"]) > deps.uploads.limit) return tooLarge();
        req.setTimeout(120_000, () => req.destroy(new UploadError(408, "Upload stalled for two minutes")));
        try {
          const file = await deps.uploads.save(url.searchParams.get("name"), req.headers["content-type"], req);
          log.info(`${device.name} uploaded ${file.name} (${file.size} bytes)`);
          return sendJson(res, 200, file);
        } catch (err) {
          req.resume();
          if (err instanceof UploadTooLargeError) return tooLarge();
          throw err;
        } finally {
          req.setTimeout(0);
        }
      }
      return sendJson(res, 404, { error: "Not found" });
    } catch (err) {
      log.error(`${req.method} ${url.pathname} failed`, err);
      if (!res.headersSent) sendJson(res, 500, { error: "Internal error" });
      else res.destroy();
    }
  };

  const onUpgrade = (req: http.IncomingMessage, socket: Duplex, head: Buffer) => {
    const url = new URL(req.url ?? "/", "http://localhost");
    if (url.pathname !== "/acp") {
      socket.end("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n");
      return;
    }
    const device = deps.devices.authenticate(bearer(req, url));
    if (!device) {
      socket.end("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n");
      return;
    }
    const frontend = new FrontendConnection(device.name, deps, device.id);
    const upgrade = acpServer.prepareWebSocketUpgrade({ agent: frontend.app });
    const onHeaders = (headers: string[], request: http.IncomingMessage) => {
      if (request === req) headers.push(`Acp-Connection-Id: ${upgrade.connectionId}`);
    };
    wss.on("headers", onHeaders);
    const failed = () => {
      wss.off("headers", onHeaders);
      upgrade.reject();
    };
    socket.once("error", failed);
    try {
      wss.handleUpgrade(req, socket, head, (ws) => {
        wss.off("headers", onHeaders);
        socket.off("error", failed);
        sockets.add(ws);
        if (url.searchParams.get("codeawCompression") === "gzip") enableGzipFrames(ws);
        heartbeat(ws);
        ws.once("close", () => {
          sockets.delete(ws);
          frontend.dispose();
        });
        upgrade.accept(ws as never);
        log.info(`${device.name} connected`);
      });
    } catch (err) {
      failed();
      socket.destroy(err as Error);
    }
  };

  const close = async () => {
    for (const ws of sockets) ws.terminate();
    await acpServer.close();
  };
  return { onRequest, onUpgrade, close };
}

function heartbeat(ws: WebSocket): void {
  let missed = 0;
  ws.on("pong", () => {
    missed = 0;
  });
  const timer = setInterval(() => {
    if (missed >= 2) {
      ws.terminate();
      return;
    }
    missed++;
    try {
      ws.ping();
    } catch {
      ws.terminate();
    }
  }, HEARTBEAT_MS);
  timer.unref();
  ws.once("close", () => clearInterval(timer));
}
