import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

export function desktopEnvironment(env: NodeJS.ProcessEnv = process.env, platform = process.platform, home = os.homedir()): NodeJS.ProcessEnv {
  if (platform !== "darwin") return { ...env };
  const directories = [path.join(env.CODEAW_HOME ?? path.join(home, ".codeaw"), "runtime/node/bin"),
    ...(env.PATH ?? "").split(path.delimiter), path.join(home, ".local/bin"), path.join(home, ".npm-global/bin"),
    "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"];
  return { ...env, PATH: [...new Set(directories.filter(Boolean))].join(path.delimiter) };
}

/**
 * What a Claude Code session (the CLI, or the Claude desktop app's Code tab) sets for the
 * commands it runs: its own identity, and the desktop app's host-managed login, which tells
 * a Claude Code started from that environment to wait for credentials only the app can give
 * ("Not logged in" / "Authentication required"). Also the default-model aliases the app maps
 * to its own gateway, and the codeaw MCP endpoint of a chat that started this bridge.
 */
const CLAUDE_SESSION_VARIABLE = /^(?:CLAUDECODE|CLAUDE_PID|CLAUDE_EFFORT|CLAUDE_CHROME_\w+|CLAUDE_CODE_\w+|CLAUDE_AGENT_SDK_\w+|ANTHROPIC_DEFAULT_\w+_MODEL|CODEAW_MCP_(?:URL|TOKEN))$/i;
/** Settings people give every Claude Code themselves, which a session passes on unchanged. */
const USER_CLAUDE_VARIABLES = new Set(["CLAUDE_CODE_GIT_BASH_PATH"]);

/** The variables to drop when this process was started from inside a Claude Code session. */
export function claudeSessionVariables(env: NodeJS.ProcessEnv): string[] {
  const names = Object.keys(env);
  const inside = names.some((name) => /^(?:CLAUDECODE|CLAUDE_CODE_ENTRYPOINT)$/i.test(name) && !!env[name]);
  return inside ? names.filter((name) => CLAUDE_SESSION_VARIABLE.test(name) && !USER_CLAUDE_VARIABLES.has(name.toUpperCase())) : [];
}

/**
 * A bridge started from a Claude Code session (by an agent, or a terminal it opened) must not
 * hand that session's variables to the agents, terminals and updates it starts. Returns the
 * names removed.
 */
export function leaveClaudeSession(env: NodeJS.ProcessEnv = process.env): string[] {
  const names = claudeSessionVariables(env);
  for (const name of names) delete env[name];
  return names;
}

export function resolveCommand(command: string, env = desktopEnvironment()): string | undefined {
  // Copying process.env makes a plain object: Windows' Path/PATHEXT lookups
  // must remain case-insensitive after config environment variables are merged.
  const value = (name: string) => env[name] ?? (process.platform === "win32"
    ? env[Object.keys(env).find((key) => key.toUpperCase() === name) ?? ""] : undefined);
  const candidates = /[\\/]/.test(command) ? [command] : (value("PATH") ?? "").split(path.delimiter).flatMap((directory) =>
    process.platform === "win32" ? [path.join(directory, command), ...(value("PATHEXT") ?? ".COM;.EXE;.BAT;.CMD").split(";")
      .map((extension) => path.join(directory, command + extension))] : [path.join(directory, command)]);
  return candidates.find((candidate) => {
    try { fs.accessSync(candidate, process.platform === "win32" ? fs.constants.F_OK : fs.constants.X_OK); return fs.statSync(candidate).isFile(); }
    catch { return false; }
  });
}

/** Store updates delete versioned WindowsApps paths; preserve all custom paths. */
export function recoverCodexPath(env: NodeJS.ProcessEnv, platform = process.platform): NodeJS.ProcessEnv {
  const configured = env.CODEX_PATH;
  if (platform !== "win32" || !configured || !/[\\/]WindowsApps[\\/]OpenAI\.Codex_[^\\/]+[\\/]/i.test(configured) || fs.existsSync(configured)) return env;
  const root = configured.match(/^(.*[\\/]WindowsApps)[\\/]OpenAI\.Codex_[^\\/]+[\\/]app[\\/]resources[\\/]codex\.exe$/i)?.[1];
  if (root) {
    try {
      const packages = fs.readdirSync(root).filter((name) => /^OpenAI\.Codex_/.test(name)).sort((a, b) => b.localeCompare(a, undefined, { numeric: true }));
      for (const name of packages) {
        const executable = path.join(root, name, "app", "resources", "codex.exe");
        try { if (fs.statSync(executable).isFile()) return { ...env, CODEX_PATH: executable }; } catch { /* Try other installed packages. */ }
      }
    } catch { /* WindowsApps enumeration may be restricted; try the package registry. */ }
    // Normal users cannot enumerate WindowsApps. The package registry exposes
    // this user's installed Codex location without changing directory permissions.
    if (path.resolve(root).toLowerCase() === path.resolve(path.join(env.ProgramFiles ?? "C:\\Program Files", "WindowsApps")).toLowerCase()) {
      const result = spawnSync("powershell.exe", ["-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-Command",
        "$ErrorActionPreference='Stop'; @(Get-AppxPackage -Name OpenAI.Codex | Sort-Object Version -Descending | ForEach-Object { Join-Path $_.InstallLocation 'app/resources/codex.exe' }) | ConvertTo-Json -Compress"],
        { windowsHide: true, encoding: "utf8", timeout: 8000 });
      try {
        const found: unknown = JSON.parse(result.stdout);
        const paths = Array.isArray(found) ? found : [found];
        for (const executable of paths) {
          try { if (typeof executable === "string" && fs.statSync(executable).isFile()) return { ...env, CODEX_PATH: executable }; }
          catch { /* A package may have disappeared during an update; try the next. */ }
        }
      } catch { /* No registered package, or a package currently updating. */ }
    }
  }
  const local = env.LOCALAPPDATA ?? env.LocalAppData;
  if (!local) return env;
  const stable = path.join(local, "Programs", "OpenAI", "Codex", "bin", "codex.exe");
  try { if (fs.statSync(stable).isFile()) return { ...env, CODEX_PATH: stable }; } catch { /* Keep the original error when no replacement exists. */ }
  return env;
}
