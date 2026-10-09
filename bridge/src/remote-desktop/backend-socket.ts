import { Duplex } from "node:stream";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import type { GatewayManifest } from "./gateway-config.js";

/** Attests the pipe server's Windows SID on the same handle used for HTTP. */
export class BackendSocket extends Duplex {
  connecting = true;
  private child: ChildProcessWithoutNullStreams;
  private timeout?: NodeJS.Timeout;
  private handshake: NodeJS.Timeout;
  constructor(manifest: GatewayManifest) {
    super();
    this.child = spawn(manifest.helper, ["--tunnel", manifest.backendPipe, manifest.ownerSid], { windowsHide: true, stdio: "pipe" });
    this.handshake = setTimeout(() => this.destroy(new Error("Backend unavailable")), 3000); this.handshake.unref();
    let marker = "";
    this.child.stderr.on("data", (data: Buffer) => {
      marker += data.toString(); if (marker.length > 64) this.destroy(new Error("Backend unavailable"));
      if (/^READY\r?\n$/.test(marker) && this.connecting) { clearTimeout(this.handshake); this.connecting = false; this.emit("connect"); }
    });
    this.child.stdout.on("data", (data: Buffer) => { if (!this.push(data)) this.child.stdout.pause(); });
    this.child.stdout.on("end", () => this.push(null));
    this.child.stdin.on("error", () => this.destroy(new Error("Backend unavailable")));
    this.child.on("error", () => this.destroy(new Error("Backend unavailable")));
    this.child.on("exit", (code) => { if (code !== 0 || this.connecting) this.destroy(new Error("Backend unavailable")); });
  }
  override _read() { this.child.stdout.resume(); }
  override _write(chunk: Buffer, encoding: BufferEncoding, callback: (error?: Error | null) => void) { this.child.stdin.write(chunk, encoding, callback); }
  override _final(callback: (error?: Error | null) => void) { this.child.stdin.end(callback); }
  override _destroy(error: Error | null, callback: (error?: Error | null) => void) {
    if (this.timeout) clearTimeout(this.timeout); this.child.stdin.end(); this.child.kill(); callback(error);
    clearTimeout(this.handshake);
  }
  setTimeout(milliseconds: number, callback?: () => void) {
    if (this.timeout) clearTimeout(this.timeout);
    if (callback) this.once("timeout", callback);
    if (milliseconds > 0) { this.timeout = setTimeout(() => this.emit("timeout"), milliseconds); this.timeout.unref(); }
    return this;
  }
  setNoDelay() { return this; }
  setKeepAlive() { return this; }
  ref() { return this; }
  unref() { return this; }
}
