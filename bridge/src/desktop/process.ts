import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { controlAddress, runningStatus } from "./control.js";
import { TRAY_SCRIPT } from "./windows-tray.js";

/** Launch in the caller's interactive session, including when the bridge runs in SCM Session 0. */
export async function launchDesktop(file: string): Promise<void> {
  if (process.platform !== "win32") throw new Error("Native tray and windows are currently available on Windows");
  const directory = path.join(path.dirname(file), "runtime");
  fs.mkdirSync(directory, { recursive: true });
  const script = path.join(directory, "tray.ps1");
  fs.writeFileSync(script, "\ufeff" + TRAY_SCRIPT, "utf8");
  const fd = fs.openSync(path.join(path.dirname(file), "desktop.log"), "a", 0o600);
  try {
    await new Promise<void>((resolve, reject) => {
      const child = spawn("powershell.exe", ["-NoProfile", "-STA", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass",
        "-File", script, "-PipeName", controlAddress(file).replace(/^\\\\\.\\pipe\\/, "")],
      { windowsHide: true, detached: true, stdio: ["ignore", fd, fd] });
      child.once("error", reject);
      child.once("spawn", () => { child.unref(); resolve(); });
    });
  } finally { fs.closeSync(fd); }
}

/** Works for Node source/builds and Bun's standalone executable. */
export function bridgeInvocation(): { executable: string; args: string[] } {
  const bundled = !!(globalThis as typeof globalThis & { Bun?: { isStandaloneExecutable?: boolean } }).Bun?.isStandaloneExecutable;
  if (bundled) return { executable: process.execPath, args: [] };
  const entry = fileURLToPath(new URL("../index.js", import.meta.url));
  const source = !fs.existsSync(entry);
  return { executable: process.execPath, args: [...(source && !process.versions.bun ? ["--import", import.meta.resolve("tsx")] : []),
    source ? entry.replace(/\.js$/, ".ts") : entry] };
}

export async function startBackground(file: string, options: { port?: number; tray?: boolean; debug?: boolean } = {}) {
  for (let attempt = 0; attempt < 100; attempt++) {
    const existing = await runningStatus(file);
    if (!existing) break;
    if (existing.state === "running") return existing;
    if (existing.state === "error") throw new Error("Bridge is in an error state. Fix the config and run codeaw-bridge restart.");
    if (attempt === 99) throw new Error("Existing bridge did not finish starting or stopping");
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  const home = path.dirname(file);
  fs.mkdirSync(home, { recursive: true });
  const logFile = path.join(home, "bridge.log");
  // Rotate before opening the inherited descriptor; no log contents enter the CLI response.
  if (fs.existsSync(logFile) && fs.statSync(logFile).size > 5 * 1024 * 1024) {
    fs.rmSync(logFile + ".1", { force: true });
    fs.renameSync(logFile, logFile + ".1");
  }
  const fd = fs.openSync(logFile, "a", 0o600);
  const invocation = bridgeInvocation();
  const args = [...invocation.args, "start", "--headless", "--config", file];
  if (options.port !== undefined) args.push("--port", String(options.port));
  if (options.tray) args.push("--tray");
  if (options.debug) args.push("--debug");
  let error: Error | undefined;
  let exited = false;
  try {
    const child = spawn(invocation.executable, args, { cwd: home, windowsHide: true, detached: true, stdio: ["ignore", fd, fd] });
    child.once("error", (err) => { error = err; });
    child.once("exit", () => { exited = true; });
    child.unref();
  } finally { fs.closeSync(fd); }
  for (let attempt = 0; attempt < 100; attempt++) {
    if (error) throw error;
    const status = await runningStatus(file);
    if (status?.state === "running") return status;
    if (exited) throw new Error(`Background bridge could not start. See ${logFile}`);
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`Background bridge startup timed out. See ${logFile}`);
}
