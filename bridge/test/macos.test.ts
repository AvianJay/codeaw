import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { desktopEnvironment, resolveCommand } from "../src/util/environment.js";
import { nodeArchive, npmEnvironment } from "../src/agents/node-runtime.js";
import { loadConfig, writeDefaultConfig } from "../src/config.js";
import { AgentInstaller } from "../src/agents/install.js";
import { platformTarget } from "../src/agents/registry.js";
import { AgentProcess, type AgentHandlers } from "../src/backend/agent-process.js";
import { launchdPlist } from "../src/desktop/service.js";

const homes: string[] = [];
function home(): string { const directory = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-macos-")); homes.push(directory); return directory; }
afterEach(() => { vi.unstubAllEnvs(); for (const directory of homes.splice(0)) fs.rmSync(directory, { recursive: true, force: true }); });

describe.skipIf(process.platform === "win32")("macOS desktop support", () => {
  it("finds commands with a minimal Finder PATH and preserves user directories", () => {
    const directory = home();
    const bin = path.join(directory, ".local/bin");
    fs.mkdirSync(bin, { recursive: true });
    const command = path.join(bin, "codeaw-fixture");
    fs.writeFileSync(command, "#!/bin/sh\nexit 0\n", { mode: 0o755 });
    const env = desktopEnvironment({ PATH: "/usr/bin:/bin" }, "darwin", directory);
    expect(env.PATH?.split(path.delimiter)).toContain("/opt/homebrew/bin");
    expect(env.PATH?.split(path.delimiter)).toContain("/usr/local/bin");
    expect(resolveCommand("codeaw-fixture", env)).toBe(command);
    expect(desktopEnvironment({ PATH: "unchanged" }, "linux").PATH).toBe("unchanged");
  });

  it("does not invent an installed Claude agent in a fresh config", () => {
    const directory = home();
    vi.stubEnv("PATH", directory);
    const file = path.join(directory, "config.yaml");
    writeDefaultConfig(file);
    expect(loadConfig(file).config.agents.claude).toBeUndefined();
  });

  it("selects only a checksummed Node 24 archive for the matching Mac architecture", () => {
    const checksum = "a".repeat(64);
    const index = `${checksum}  node-v24.19.0-darwin-x64.tar.gz\n${"b".repeat(64)}  node-v24.19.0-darwin-arm64.tar.gz\n`;
    expect(nodeArchive(index, "x64")).toEqual({ name: "node-v24.19.0-darwin-x64.tar.gz", sha256: checksum });
    expect(nodeArchive(index, "arm64").sha256).toBe("b".repeat(64));
    expect(() => nodeArchive(index, "ia32")).toThrow(/architecture/);
    expect(() => nodeArchive("unverified node.tar.gz", "x64")).toThrow(/verified/);
  });

  it("reuses working npm without a runtime download", async () => {
    const directory = home();
    const bin = path.join(directory, "bin");
    fs.mkdirSync(bin);
    fs.writeFileSync(path.join(bin, "npm"), "#!/bin/sh\nexit 0\n", { mode: 0o755 });
    vi.stubEnv("PATH", bin);
    const environment = await npmEnvironment(directory, new AbortController().signal, () => undefined);
    expect(environment.PATH).toContain(bin);
    expect(fs.existsSync(path.join(directory, "runtime/node"))).toBe(false);
  });

  it("reports a missing ACP executable instead of an aborted connection", async () => {
    const handlers: AgentHandlers = { onUpdate: () => undefined, onExit: () => undefined,
      onPermission: async () => ({ outcome: { outcome: "cancelled" } }),
      onElicitation: async () => ({ action: "cancel" }) };
    const agent = new AgentProcess("fixture", { name: "Fixture", command: path.join(home(), "missing-acp"), args: [], env: {}, enabled: true }, handlers, home());
    await expect(agent.ensureStarted()).rejects.toThrow(/ACP executable not found/);
    expect(agent.describe()).toMatchObject({ status: "error" });
  });

  it("normalizes aborted downloads without exposing runtime jargon", async () => {
    const file = path.join(home(), "config.yaml");
    fs.writeFileSync(file, "agents: {}\n");
    const installer = new AgentInstaller(file, undefined, {
      registry: async () => [{ id: "fixture", name: "Fixture", version: "1.0.0", description: "", distribution: {
        binary: { [platformTarget()]: { archive: "https://example.com/fixture", cmd: "fixture", args: [], env: {} } },
      } }], prepare: async () => { throw new DOMException("The operation was aborted", "AbortError"); },
    });
    await installer.start("fixture");
    expect(await installer.wait()).toMatchObject({ state: "failed", message: "Agent download timed out. Check your internet connection and retry." });
  });

  it("escapes LaunchAgent arguments and distinguishes tray login from headless service", () => {
    const invocation = { executable: "/Applications/codeaw & test/node", args: ["bridge.js"] };
    const plist = launchdPlist("/tmp/config & test.yaml", "fixture", invocation, true);
    expect(plist).toContain("codeaw &amp; test/node");
    expect(plist).toContain("<string>tray</string>");
    expect(plist).not.toContain("<string>--headless</string>");
    expect(launchdPlist("/tmp/config.yaml", "fixture", invocation)).toContain("<string>--headless</string>");
  });
});
