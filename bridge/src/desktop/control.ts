import crypto from "node:crypto";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";

export interface ControlRequest { command: string; [key: string]: unknown }
const MAX_MESSAGE = 128 * 1024;

/** Local IPC only: never expose desktop administration on the phone's HTTP listener. */
export function controlAddress(file: string): string {
  const absolute = path.resolve(file);
  const key = crypto.createHash("sha256").update(process.platform === "win32" ? absolute.toLowerCase() : absolute).digest("hex").slice(0, 24);
  return process.platform === "win32"
    ? `\\\\.\\pipe\\codeaw-${key}`
    : path.join(os.tmpdir(), `codeaw-${process.getuid?.() ?? "user"}-${key}`, "control.sock");
}

export function requestControl<T = any>(file: string, request: ControlRequest, timeout = 15_000): Promise<T> {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(controlAddress(file));
    let data = "";
    let done = false;
    const finish = (error?: Error, value?: T) => {
      if (done) return;
      done = true;
      socket.destroy();
      if (error) reject(error); else resolve(value!);
    };
    socket.setEncoding("utf8");
    socket.setTimeout(timeout, () => finish(new Error("Bridge control request timed out")));
    socket.once("connect", () => socket.write(JSON.stringify(request) + "\n"));
    socket.on("data", (chunk: string) => {
      data += chunk;
      if (data.length > MAX_MESSAGE * 2) return finish(new Error("Bridge control response too large"));
      if (!data.includes("\n")) return;
      try {
        const response = JSON.parse(data.slice(0, data.indexOf("\n")));
        finish(response.ok ? undefined : new Error(response.error ?? "Control request failed"), response.result);
      } catch { finish(new Error("Invalid bridge control response")); }
    });
    socket.once("error", (err) => finish(err));
    socket.once("close", () => finish(Object.assign(new Error("Bridge control connection closed"), { code: "ECONNRESET" })));
  });
}

export function isUnavailable(error: unknown): boolean {
  return ["ENOENT", "ECONNREFUSED", "ECONNRESET"].includes((error as NodeJS.ErrnoException).code ?? "");
}

export async function runningStatus(file: string): Promise<any | undefined> {
  try { return await requestControl(file, { command: "status" }, 1500); }
  catch (err) { if (isUnavailable(err)) return undefined; throw err; }
}

export async function serveControl(file: string, handler: (request: ControlRequest) => Promise<unknown>): Promise<net.Server> {
  const address = controlAddress(file);
  if (process.platform !== "win32") {
    fs.mkdirSync(path.dirname(address), { recursive: true, mode: 0o700 });
    fs.chmodSync(path.dirname(address), 0o700);
    if (fs.existsSync(address)) {
      if (await runningStatus(file)) throw new Error("Bridge is already running for this config");
      fs.unlinkSync(address);
    }
  }
  const server = net.createServer((socket) => {
    socket.setEncoding("utf8");
    socket.setTimeout(20_000, () => socket.destroy());
    socket.on("error", () => undefined);
    let data = "";
    let accepted = false;
    socket.on("data", (chunk: string) => {
      if (accepted) return;
      data += chunk;
      if (data.length > MAX_MESSAGE) { socket.destroy(); return; }
      if (!data.includes("\n")) return;
      accepted = true;
      void (async () => {
        try {
          const request = JSON.parse(data.slice(0, data.indexOf("\n")));
          if (!request || typeof request.command !== "string") throw new Error("Invalid control command");
          const result = await handler(request);
          socket.end(JSON.stringify({ ok: true, result }) + "\n");
        } catch (err) {
          socket.end(JSON.stringify({ ok: false, error: (err as Error).message }) + "\n");
        }
      })();
    });
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(address, () => { server.off("error", reject); resolve(); });
  });
  if (process.platform !== "win32") fs.chmodSync(address, 0o600);
  return server;
}
