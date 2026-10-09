import crypto from "node:crypto";
import http from "node:http";
import net from "node:net";
import type { Duplex } from "node:stream";

export interface PrivateHttpListener {
  close(callback?: () => void): unknown;
  closeAllConnections(): void;
  closeIdleConnections(): void;
  /** Present only for the authenticated loopback transport used by Bun on Windows. */
  tcpPort?: number;
}

/** Bun's Windows HTTP listener cannot bind named pipes, while its net listener can. */
export async function listenPrivateHttp(pipe: string, request: http.RequestListener,
  upgrade: (request: http.IncomingMessage, socket: Duplex, head: Buffer) => void,
  protect: () => Promise<void>, forceRelay = process.platform === "win32" && !!process.versions.bun): Promise<PrivateHttpListener> {
  if (!forceRelay) {
    const server = http.createServer({ requestTimeout: 120_000 }, request);
    server.on("upgrade", upgrade);
    try {
      await new Promise<void>((resolve, reject) => { server.once("error", reject); server.listen(pipe, resolve); });
      await protect();
      return server;
    } catch (error) { server.closeAllConnections(); server.close(); throw error; }
  }

  // The loopback socket accepts only the per-process nonce inserted by the ACL-protected pipe.
  // Neither the nonce nor HTTP headers are written to disk or logged.
  const headerName = "x-codeaw-backend-nonce";
  const nonce = crypto.randomBytes(32).toString("hex");
  const authorized = (req: http.IncomingMessage) => {
    const value = req.headers[headerName];
    delete req.headers[headerName];
    return typeof value === "string" && /^[a-f0-9]{64}$/.test(value) && crypto.timingSafeEqual(Buffer.from(value), Buffer.from(nonce));
  };
  const httpServer = http.createServer({ requestTimeout: 120_000 }, (req, res) => {
    if (!authorized(req)) { res.destroy(); return; }
    request(req, res);
  });
  httpServer.on("upgrade", (req, socket, head) => { if (authorized(req)) upgrade(req, socket, head); else socket.destroy(); });
  const connections = new Set<net.Socket>();
  const pending = new Set<net.Socket>();
  let ready = false;
  let port = 0;
  const pipeServer = net.createServer((socket) => {
    connections.add(socket);
    socket.once("close", () => { connections.delete(socket); pending.delete(socket); });
    socket.on("error", () => socket.destroy());
    // Keep the ACL helper's security-only handle alive, then discard every pre-ACL connection.
    if (!ready) { socket.pause(); pending.add(socket); return; }
    let buffer = Buffer.alloc(0);
    const receive = (chunk: Buffer) => {
      buffer = Buffer.concat([buffer, chunk]);
      const end = buffer.indexOf("\r\n\r\n");
      if (end < 0) { if (buffer.length > 64 * 1024) socket.destroy(); return; }
      if (end > 64 * 1024) { socket.destroy(); return; }
      socket.pause(); socket.off("data", receive);
      const lines = buffer.subarray(0, end).toString("latin1").split("\r\n");
      const websocket = lines.some((line) => /^upgrade:\s*websocket\s*$/i.test(line));
      const headers = lines.filter((line, index) => index === 0 || (!new RegExp(`^${headerName}:`, "i").test(line) && !/^connection:/i.test(line)));
      headers.push(`${headerName}: ${nonce}`, `Connection: ${websocket ? "Upgrade" : "close"}`);
      const backend = net.connect({ host: "127.0.0.1", port });
      connections.add(backend);
      const clean = () => { socket.destroy(); backend.destroy(); };
      backend.on("error", clean); socket.once("close", clean);
      backend.once("close", () => { connections.delete(backend); if (!backend.readableEnded) socket.destroy(); });
      backend.once("connect", () => {
        backend.write(Buffer.from(headers.join("\r\n") + "\r\n\r\n", "latin1"));
        if (buffer.length > end + 4) backend.write(buffer.subarray(end + 4));
        buffer = Buffer.alloc(0);
        backend.pipe(socket); socket.pipe(backend); socket.resume();
      });
    };
    socket.on("data", receive);
  });
  const listener: PrivateHttpListener = {
    close(callback) {
      ready = false;
      let remaining = 2;
      const closed = () => { if (--remaining === 0) callback?.(); };
      pipeServer.close(closed); httpServer.close(closed);
    },
    closeAllConnections() { for (const socket of connections) socket.destroy(); httpServer.closeAllConnections(); },
    closeIdleConnections() { httpServer.closeIdleConnections?.(); },
  };
  try {
    await new Promise<void>((resolve, reject) => { httpServer.once("error", reject); httpServer.listen(0, "127.0.0.1", resolve); });
    port = (httpServer.address() as net.AddressInfo).port;
    listener.tcpPort = port;
    await new Promise<void>((resolve, reject) => { pipeServer.once("error", reject); pipeServer.listen(pipe, resolve); });
    await protect();
    for (const socket of pending) socket.destroy();
    pending.clear();
    ready = true;
    return listener;
  } catch (error) { listener.closeAllConnections(); listener.close(); throw error; }
}
