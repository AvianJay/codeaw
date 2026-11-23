import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { claudeSessionVariables, desktopEnvironment, leaveClaudeSession, recoverCodexPath, resolveCommand } from "../src/util/environment.js";

const directories: string[] = [];
afterEach(() => {
  for (const directory of directories.splice(0)) fs.rmSync(directory, { recursive: true, force: true });
});

it("recovers a deleted Store Codex executable after an update without replacing custom paths", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-codex-path-"));
  directories.push(directory);
  const stable = path.join(directory, "Programs", "OpenAI", "Codex", "bin", "codex.exe");
  fs.mkdirSync(path.dirname(stable), { recursive: true });
  fs.writeFileSync(stable, "installed CLI fixture");
  const old = path.join(directory, "WindowsApps", "OpenAI.Codex_old_x64", "app", "resources", "codex.exe");
  const env = { LOCALAPPDATA: directory, CODEX_PATH: old, CUSTOM_VALUE: "preserved" };
  expect(recoverCodexPath(env, "win32")).toEqual({ ...env, CODEX_PATH: stable });
  expect(env.CODEX_PATH).toBe(old);
  expect(recoverCodexPath({ ...env, CODEX_PATH: path.join(directory, "custom.exe") }, "win32").CODEX_PATH).toBe(path.join(directory, "custom.exe"));
  expect(recoverCodexPath(env, "linux")).toBe(env);
  const current = path.join(directory, "WindowsApps", "OpenAI.Codex_26.930.6422.0_x64", "app", "resources", "codex.exe");
  fs.mkdirSync(path.dirname(current), { recursive: true }); fs.writeFileSync(current, "current Desktop CLI");
  expect(recoverCodexPath(env, "win32").CODEX_PATH).toBe(current);
  fs.mkdirSync(path.dirname(old), { recursive: true }); fs.writeFileSync(old, "existing Store fixture");
  expect(recoverCodexPath(env, "win32")).toBe(env);
});

it("drops a Claude desktop session's variables, and only when started from one", () => {
  const user = { Path: "C:\\Windows", ANTHROPIC_BASE_URL: "https://proxy.example", CLAUDE_CONFIG_DIR: "D:\\claude", CLAUDE_CODE_GIT_BASH_PATH: "C:\\Git\\bin\\bash.exe", CLAUDE_CODE_MAX_OUTPUT_TOKENS: "9000" };
  const session = {
    CLAUDECODE: "1", CLAUDE_CODE_ENTRYPOINT: "claude-desktop-3p", CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST: "1",
    CLAUDE_CODE_HOST_AUTH_ENV_VAR: "ANTHROPIC_AUTH_TOKEN", CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH: "1", CLAUDE_AGENT_SDK_VERSION: "0.3.330",
    CLAUDE_PID: "42", CLAUDE_EFFORT: "high", ANTHROPIC_DEFAULT_HAIKU_MODEL: "gateway-haiku", CODEAW_MCP_TOKEN: "t", CODEAW_MCP_URL: "http://127.0.0.1:1/mcp",
  };
  const env: NodeJS.ProcessEnv = { ...user, ...session };
  expect(leaveClaudeSession(env).sort()).toEqual([...Object.keys(session), "CLAUDE_CODE_MAX_OUTPUT_TOKENS"].sort());
  // A user's own Claude Code settings outside the session family stay.
  expect(env).toEqual({ Path: "C:\\Windows", ANTHROPIC_BASE_URL: "https://proxy.example", CLAUDE_CONFIG_DIR: "D:\\claude", CLAUDE_CODE_GIT_BASH_PATH: "C:\\Git\\bin\\bash.exe" });
  // Started any other way, nothing is touched, not even variables a user set on purpose.
  const plain: NodeJS.ProcessEnv = { ...user, CLAUDE_CODE_USE_BEDROCK: "1" };
  expect(leaveClaudeSession(plain)).toEqual([]);
  expect(plain).toEqual({ ...user, CLAUDE_CODE_USE_BEDROCK: "1" });
  expect(claudeSessionVariables({ CLAUDECODE: "", CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST: "1" })).toEqual([]);
  expect(claudeSessionVariables({ claudecode: "1", Claude_Code_Host_Auth_Env_Var: "X" })).toEqual(["claudecode", "Claude_Code_Host_Auth_Env_Var"]);
});

describe.skipIf(process.platform !== "win32")("Windows command discovery", () => {
  function fixture() {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-command-"));
    directories.push(directory);
    const executable = path.join(directory, "codeaw-fixture.CMD");
    fs.writeFileSync(executable, "@exit /b 0\r\n");
    return { directory, executable };
  }

  it("finds npm command shims when the inherited Path is copied and merged", () => {
    const { directory, executable } = fixture();
    const environment = desktopEnvironment({ Path: directory, Pathext: ".CMD" });
    expect(resolveCommand("codeaw-fixture", { ...environment })).toBe(executable);
    expect(resolveCommand("missing-fixture", environment)).toBeUndefined();
  });

  it("honors an explicit PATH override alongside the inherited Path", () => {
    const { directory, executable } = fixture();
    const environment = desktopEnvironment({ Path: path.join(directory, "missing"), PATH: directory, PATHEXT: ".CMD" });
    expect(resolveCommand("codeaw-fixture", environment)).toBe(executable);
  });
});
