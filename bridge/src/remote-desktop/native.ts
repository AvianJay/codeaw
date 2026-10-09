import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import type { DesktopBackend, NativeReply } from "./protocol.js";
import { DesktopError } from "./protocol.js";

export function desktopHelper(): string | undefined {
  return [path.join(path.dirname(process.execPath), "codeaw-desktop.exe"),
    fileURLToPath(new URL("../assets/codeaw-desktop.exe", import.meta.url)),
    fileURLToPath(new URL("../../dist/assets/codeaw-desktop.exe", import.meta.url))].find((file) => fs.existsSync(file));
}

/** No stderr, input, image, SDP, or authentication material is ever logged. */
export class NativeDesktop implements DesktopBackend {
  onEvent?: (event: Record<string, any>) => void;
  private child: ChildProcessWithoutNullStreams;
  private pending = new Map<number, { resolve: (reply: NativeReply) => void; reject: (error: Error) => void; timer: NodeJS.Timeout }>();
  private buffer = Buffer.alloc(0);
  private nextId = 0;
  private closed = false;
  constructor(privilege: "user" | "system", helper = desktopHelper(), serviceWorker = false) {
    if (!helper || process.platform !== "win32") throw new DesktopError(503, "helper_missing", "請安裝支援遠端桌面的 Windows bridge");
    if (privilege === "system" && !serviceWorker) throw new DesktopError(403, "privilege_required", "請在電腦端安裝並啟用進階桌面服務");
    this.child = spawn(helper, [serviceWorker ? "--broker" : "--worker", "--privilege", privilege], { windowsHide: true, stdio: "pipe" });
    this.child.stderr.resume();
    this.child.stdout.on("data", (chunk: Buffer) => this.read(chunk));
    this.child.on("error", () => this.fail());
    this.child.on("exit", () => this.fail());
    this.child.stdin.on("error", () => this.fail());
  }
  request(command: string, params: Record<string, unknown> = {}): Promise<NativeReply> {
    if (this.closed) return Promise.reject(new DesktopError(503, "helper_stopped", "桌面元件已停止"));
    const id = ++this.nextId;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.fail(); }, 15_000); timer.unref();
      this.pending.set(id, { resolve, reject, timer });
      this.child.stdin.write(JSON.stringify({ ...params, command, id }) + "\n");
    });
  }
  private read(chunk: Buffer) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    if (this.buffer.length > 24 * 1024 * 1024) { this.fail(); return; }
    while (this.buffer.length >= 4) {
      const n = this.buffer.readUInt32LE(0);
      if (n > 1024 * 1024) { this.fail(); return; }
      if (this.buffer.length < n + 4) return;
      let header: any;
      try { header = JSON.parse(this.buffer.subarray(4, 4 + n).toString("utf8")); } catch { this.fail(); return; }
      const bytes = header.payloadBytes ?? 0;
      if (!Number.isSafeInteger(bytes) || bytes < 0 || bytes > 16 * 1024 * 1024) { this.fail(); return; }
      if (this.buffer.length < 4 + n + bytes) return;
      const payload = Buffer.from(this.buffer.subarray(4 + n, 4 + n + bytes));
      this.buffer = this.buffer.subarray(4 + n + bytes);
      const pending = this.pending.get(header.replyTo);
      if (pending) {
        clearTimeout(pending.timer); this.pending.delete(header.replyTo);
        if (header.error) pending.reject(new DesktopError(409, String(header.error.code ?? "capture_unavailable"), String(header.error.message ?? "桌面暫時無法使用")));
        else pending.resolve({ result: header.result ?? {}, payload });
      } else if (header.event) this.onEvent?.(header.event);
    }
  }
  private fail() {
    if (this.closed) return;
    this.closed = true;
    for (const p of this.pending.values()) { clearTimeout(p.timer); p.reject(new DesktopError(503, "helper_stopped", "桌面元件已停止")); }
    this.pending.clear(); this.buffer = Buffer.alloc(0);
    this.child.kill();
    this.onEvent?.({ type: "error", code: "helper_stopped", message: "桌面元件已停止" });
  }
  async dispose() {
    if (!this.closed) {
      try { await this.request("release"); } catch { /* Process failure releases worker-owned input. */ }
      this.fail();
    }
  }
}
