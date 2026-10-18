import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

export function windowsLauncher(): string {
  const helper = [path.join(path.dirname(process.execPath), "codeaw-launcher.exe"),
    fileURLToPath(new URL("../assets/codeaw-launcher.exe", import.meta.url)),
    fileURLToPath(new URL("../../dist/assets/codeaw-launcher.exe", import.meta.url))].find((file) => fs.existsSync(file));
  if (!helper) throw new Error("Windows launcher not found. Install a complete Windows release or run npm run build:desktop in bridge.");
  return helper;
}

/** The native helper inherits the environment and redirects only the child's stdio. */
export async function launchWindowsProcess(executable: string, args: string[], directory: string, logFile: string): Promise<number> {
  let output: string;
  try {
    output = (await promisify(execFile)(windowsLauncher(), ["--launch", directory, logFile, executable, ...args],
      { windowsHide: true, timeout: 15_000 })).stdout;
  } catch (error) {
    // The helper reports fixed operation names/codes, never its command or env.
    // Do not expose execFile's error message, which includes the full command.
    const stdout = (error as { stdout?: string }).stdout;
    let failure: { error?: string; code?: number } | undefined;
    try { failure = JSON.parse(stdout ?? ""); } catch { /* Missing/blocked helper. */ }
    if (failure?.error === "create_process" && failure.code === 5) {
      throw new Error(`Windows refused independent background startup (Windows error 5). Try launching from the installed shortcut. See ${logFile}`);
    }
    const operations: Record<string, string> = { open_log: "open the background log", open_stdin: "open background input",
      initialize_handles: "initialize background handles", inherit_handles: "prepare background handles", create_process: "create the background process" };
    if (failure?.error && operations[failure.error] && Number.isInteger(failure.code)) {
      throw new Error(`Cannot ${operations[failure.error]} (Windows error ${failure.code}). See ${logFile}`);
    }
    if (error instanceof Error && error.message.startsWith("Windows launcher not found.")) throw error;
    throw new Error(`Cannot run the Windows launcher. Check that codeaw-launcher.exe is installed and allowed to run. See ${logFile}`);
  }
  let pid: number | undefined;
  try { pid = JSON.parse(output).pid; } catch { /* Invalid helper response. */ }
  if (!Number.isSafeInteger(pid) || pid! <= 0) throw new Error(`Windows launcher did not return a process ID. See ${logFile}`);
  return pid!;
}
