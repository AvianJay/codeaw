import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { bridgeInvocation } from "./process.js";
import { serviceName } from "./service.js";

const exec = promisify(execFile);
const RUN_KEY = "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run";

export function loginCommand(file: string, invocation = bridgeInvocation()): string {
  const quote = (value: string) => "'" + value.replace(/'/g, "''") + "'";
  const args = [...invocation.args, "tray", "--config", file];
  const script = `& ${quote(invocation.executable)} ${args.map(quote).join(" ")} *>> ${quote(path.join(path.dirname(file), "desktop-launch.log"))}`;
  return `powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand ${Buffer.from(script, "utf16le").toString("base64")}`;
}

export async function loginStartupEnabled(file: string): Promise<boolean> {
  if (process.platform !== "win32") throw new Error("Login tray startup is available on Windows");
  try {
    await exec("reg.exe", ["query", RUN_KEY, "/v", serviceName(file)], { windowsHide: true, timeout: 5000 });
    return true;
  } catch (err) {
    if ((err as { code?: number }).code === 1) return false;
    throw new Error("Cannot query Windows login startup");
  }
}

export async function setLoginStartup(file: string, enabled: boolean): Promise<void> {
  if (process.platform !== "win32") throw new Error("Login tray startup is available on Windows");
  if (enabled) await exec("reg.exe", ["add", RUN_KEY, "/v", serviceName(file), "/t", "REG_SZ", "/d", loginCommand(file), "/f"], { windowsHide: true });
  else if (await loginStartupEnabled(file)) await exec("reg.exe", ["delete", RUN_KEY, "/v", serviceName(file), "/f"], { windowsHide: true });
}
