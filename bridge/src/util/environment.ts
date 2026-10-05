import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export function desktopEnvironment(env: NodeJS.ProcessEnv = process.env, platform = process.platform, home = os.homedir()): NodeJS.ProcessEnv {
  if (platform !== "darwin") return { ...env };
  const directories = [path.join(env.CODEAW_HOME ?? path.join(home, ".codeaw"), "runtime/node/bin"),
    ...(env.PATH ?? "").split(path.delimiter), path.join(home, ".local/bin"), path.join(home, ".npm-global/bin"),
    "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"];
  return { ...env, PATH: [...new Set(directories.filter(Boolean))].join(path.delimiter) };
}

export function resolveCommand(command: string, env = desktopEnvironment()): string | undefined {
  const candidates = /[\\/]/.test(command) ? [command] : (env.PATH ?? "").split(path.delimiter).flatMap((directory) =>
    process.platform === "win32" ? [path.join(directory, command), ...(env.PATHEXT ?? ".COM;.EXE;.BAT;.CMD").split(";")
      .map((extension) => path.join(directory, command + extension))] : [path.join(directory, command)]);
  return candidates.find((candidate) => {
    try { fs.accessSync(candidate, process.platform === "win32" ? fs.constants.F_OK : fs.constants.X_OK); return fs.statSync(candidate).isFile(); }
    catch { return false; }
  });
}
