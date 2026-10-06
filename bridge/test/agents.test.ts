import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import * as tar from "tar";
import YAML from "yaml";
import { afterEach, describe, expect, it, vi } from "vitest";
import { loadConfig } from "../src/config.js";
import { AgentInstaller, archivePath, extractArchive, prepareAgent, registerInstalledAgent, runInstaller, type InstalledAgent } from "../src/agents/install.js";
import { configAgentId, distributionFor, parseRegistry, platformTarget, type RegistryAgent } from "../src/agents/registry.js";

const homes: string[] = [];
function home() { const root = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-agents-")); homes.push(root); return root; }
function config(root = home()) {
  const file = path.join(root, "config.yaml");
  fs.writeFileSync(file, "# preserve this comment\n" + YAML.stringify({ agents: {
    codex: { name: "My Codex", command: "original", args: [], env: { TEST_VALUE: "synthetic-value" }, enabled: false, cwd: root },
  }, custom: { keep: true } }));
  return file;
}
function agent(distribution: RegistryAgent["distribution"], id = "codex-acp"): RegistryAgent {
  return parseRegistry({ agents: [{ id, name: "Test Agent", version: "1.0.0", distribution }] })[0];
}
function binary(cmd = "./agent.exe", sha256?: string) {
  return agent({ binary: { [platformTarget()]: { archive: "https://example.com/agent.zip", cmd, args: ["acp"], env: {}, sha256 } } });
}
const validZip = Buffer.from("UEsDBBQAAAAAABq1Ql14ocaiDQAAAA0AAAAJAAAAYWdlbnQuZXhlYWdlbnQgZml4dHVyZVBLAQIUABQAAAAAABq1Ql14ocaiDQAAAA0AAAAJAAAAAAAAAAAAAACAAQAAAABhZ2VudC5leGVQSwUGAAAAAAEAAQA3AAAANAAAAAAA", "base64");
const traversalZip = Buffer.from("UEsDBBQAAAAAABq1Ql2OsOglBgAAAAYAAAANAAAALi4vZXNjYXBlLnR4dGVzY2FwZVBLAQIUABQAAAAAABq1Ql2OsOglBgAAAAYAAAANAAAAAAAAAAAAAACAAQAAAAAuLi9lc2NhcGUudHh0UEsFBgAAAAABAAEAOwAAADEAAAAAAA==", "base64");

afterEach(() => {
  vi.unstubAllGlobals();
  for (const root of homes.splice(0)) {
    if (!path.resolve(root).startsWith(path.resolve(os.tmpdir()) + path.sep) || !path.basename(root).startsWith("codeaw-agents-")) throw new Error("Unsafe test cleanup path");
    fs.rmSync(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
  }
});

describe("ACP registry", () => {
  it("maps existing agent IDs and selects the current platform before package fallbacks", () => {
    expect(configAgentId("claude-acp")).toBe("claude");
    expect(configAgentId("codex-acp")).toBe("codex");
    expect(configAgentId("antigravity-acp")).toBe("antigravity");
    expect(configAgentId("new-agent")).toBe("new-agent");
    expect(platformTarget("win32", "arm64")).toBe("windows-aarch64");
    expect(platformTarget("darwin", "x64")).toBe("darwin-x86_64");
    const entry = agent({ ...binary().distribution, npx: { package: "test@1.0.0", args: [], env: {} } });
    expect(distributionFor(entry)?.kind).toBe("binary");
    expect(distributionFor(entry, "unsupported")?.kind).toBe("npx");
    expect(distributionFor(binary(), "unsupported")).toBeUndefined();
  });

  it("skips malformed entries without losing the rest of the catalog", () => {
    expect(parseRegistry({ agents: [{ id: "../unsafe" }, binary(), binary()] })).toHaveLength(1);
    expect(() => parseRegistry({ agents: [] })).toThrow(/no supported entries/);
    expect(() => parseRegistry({})).toThrow(/invalid index/);
  });
});

describe("agent installation", () => {
  it("changes an AGY CLI entry back to ACP when the official ACP adapter is installed", () => {
    const root = home(); const file = path.join(root, "config.yaml");
    fs.writeFileSync(file, YAML.stringify({ agents: { antigravity: { name: "My AGY", command: "agy", args: [], transport: "agy", env: { CUSTOM: "keep" }, enabled: true } } }));
    registerInstalledAgent(file, { id: "antigravity", name: "Antigravity ACP", version: "1.0.0", directory: root, config: { name: "Antigravity ACP", command: "agy_acp_server.exe", args: [], env: {}, enabled: true } });
    const updated = loadConfig(file).config.agents.antigravity;
    expect(updated.transport).toBeUndefined();
    expect(updated.command).toBe("agy_acp_server.exe");
    expect(updated.name).toBe("My AGY");
    expect(updated.env.CUSTOM).toBe("keep");
  });

  it("handles macOS alias paths while retaining archive containment checks", async () => {
    const root = home();
    const alias = path.join(home(), "alias");
    fs.symlinkSync(root, alias, process.platform === "win32" ? "junction" : "dir");
    vi.stubGlobal("fetch", vi.fn(async () => new Response(validZip)));
    const installed = await prepareAgent(alias, binary());
    expect(fs.readFileSync(installed.config.command, "utf8")).toBe("agent fixture");
    expect(installed.directory).toContain(fs.realpathSync(root));
  });

  it("downloads, verifies and extracts a binary with its ACP arguments", async () => {
    const root = home();
    const sha256 = crypto.createHash("sha256").update(validZip).digest("hex");
    vi.stubGlobal("fetch", vi.fn(async () => new Response(validZip)));
    const installed = await prepareAgent(root, binary("./agent.exe", sha256));
    expect(installed.id).toBe("codex");
    expect(installed.config.args).toEqual(["acp"]);
    expect(fs.readFileSync(installed.config.command, "utf8")).toBe("agent fixture");
    expect(fs.existsSync(path.join(installed.directory, "download.archive"))).toBe(false);
    expect(JSON.parse(fs.readFileSync(path.join(installed.directory, "installed.json"), "utf8"))).toEqual({ id: "codex-acp", version: "1.0.0" });
  });

  it("rejects checksum failures and leaves existing installs and config intact", async () => {
    const root = home();
    const file = config(root);
    const original = fs.readFileSync(file, "utf8");
    const old = path.join(root, "agents", "codex-acp", "old");
    fs.mkdirSync(old, { recursive: true }); fs.writeFileSync(path.join(old, "keep"), "working version");
    vi.stubGlobal("fetch", vi.fn(async () => new Response(validZip)));
    await expect(prepareAgent(root, binary("./agent.exe", "0".repeat(64)))).rejects.toThrow(/SHA-256/);
    expect(fs.readdirSync(path.dirname(old))).toEqual(["old"]);
    expect(fs.readFileSync(file, "utf8")).toBe(original);
    expect(fs.readFileSync(path.join(old, "keep"), "utf8")).toBe("working version");
  });

  it("accepts Windows separators in registry commands and sets the archive working directory", async () => {
    const entry = binary("./bin\\agent.exe");
    entry.distribution.binary![platformTarget()].archive = "https://example.com/agent.exe";
    vi.stubGlobal("fetch", vi.fn(async () => new Response("raw binary fixture")));
    const installed = await prepareAgent(home(), entry);
    expect(installed.config.command).toBe(path.join(installed.directory, "bin", "agent.exe"));
    expect(installed.config.cwd).toBe(installed.directory);
  });

  it("rejects unsafe archive paths and ZIP traversal", async () => {
    const root = home();
    for (const entry of ["../escape", "/escape", "C:/escape", "..\\escape", "file:stream", "dir/../escape"]) {
      expect(() => archivePath(root, entry)).toThrow(/unsafe path/);
    }
    const zip = path.join(root, "unsafe.zip"); fs.writeFileSync(zip, traversalZip);
    const destination = path.join(root, "extracted"); fs.mkdirSync(destination);
    await expect(extractArchive(zip, destination, "zip")).rejects.toThrow();
    expect(fs.existsSync(path.join(root, "escape.txt"))).toBe(false);
  });

  it("extracts tar.gz executables and refuses archive links", async () => {
    const root = home();
    fs.writeFileSync(path.join(root, "agent"), "tar fixture");
    const file = path.join(root, "agent.tar.gz");
    await tar.c({ file, gzip: true, cwd: root }, ["agent"]);
    const destination = path.join(root, "extracted"); fs.mkdirSync(destination);
    await extractArchive(file, destination, "tar");
    expect(fs.readFileSync(path.join(destination, "agent"), "utf8")).toBe("tar fixture");
    // Hardlinks can be created without Windows developer mode or elevation.
    fs.linkSync(path.join(root, "agent"), path.join(root, "link"));
    const links = path.join(root, "links.tar.gz");
    // tar's async hardlink pack can finish gzip twice; build this fixture synchronously.
    tar.c({ file: links, gzip: true, cwd: root, sync: true }, ["agent", "link"]);
    const other = path.join(root, "other"); fs.mkdirSync(other);
    await expect(extractArchive(links, other, "tar")).rejects.toThrow(/unsafe entries/);
  });

  it("installs npm packages locally and resolves the executable without a global PATH change", async () => {
    const root = home();
    const run = vi.fn(async (_command, _args, directory: string) => {
      const pkgDir = path.join(directory, "node_modules", "@test", "adapter");
      fs.mkdirSync(pkgDir, { recursive: true });
      fs.writeFileSync(path.join(pkgDir, "package.json"), JSON.stringify({ bin: { "agent-cli": "cli.js" } }));
      fs.writeFileSync(path.join(pkgDir, "cli.js"), "fixture");
      const binDir = path.join(directory, "node_modules", ".bin"); fs.mkdirSync(binDir);
      fs.writeFileSync(path.join(binDir, "agent-cli" + (process.platform === "win32" ? ".cmd" : "")), "fixture");
    });
    const installed = await prepareAgent(root, agent({ npx: { package: "@test/adapter@1.0.0", args: ["--acp"], env: { FIXTURE: "yes" } } }), undefined, undefined, { run });
    expect(run.mock.calls[0][0]).toBe("npm");
    expect(run.mock.calls[0][1]).toContain("--prefix");
    expect(run.mock.calls[0][1]).toContain("@test/adapter@1.0.0");
    expect(installed.config.command).toContain(path.join("node_modules", ".bin", "agent-cli"));
    expect(installed.config.env).toEqual({ FIXTURE: "yes" });
    expect(installed.config.args).toEqual(["--acp"]);
  });

  it("normalizes Python package versions and isolates uv tools", async () => {
    const run = vi.fn(async (_command, _args, _directory, _signal, env: NodeJS.ProcessEnv = {}) => {
      fs.mkdirSync(env.UV_TOOL_BIN_DIR!, { recursive: true });
      fs.writeFileSync(path.join(env.UV_TOOL_BIN_DIR!, "test-agent" + (process.platform === "win32" ? ".exe" : "")), "fixture");
    });
    const installed = await prepareAgent(home(), agent({ uvx: { package: "test-agent@1.0.0", args: ["acp"], env: {} } }), undefined, undefined, { run });
    expect(run.mock.calls[0][0]).toBe("uv");
    expect(run.mock.calls[0][1]).toContain("test-agent==1.0.0");
    expect(installed.config.command).toContain(path.join(installed.directory, "bin"));
  });

  it("installs and launches a real npm executable from a local fixture in a path with spaces", async () => {
    const root = path.join(home(), "space's folder");
    const pkg = path.join(root, "package"); fs.mkdirSync(pkg, { recursive: true });
    fs.writeFileSync(path.join(pkg, "package.json"), JSON.stringify({ name: "codeaw-acp-fixture", version: "1.0.0", bin: { "fixture-agent": "cli.js" } }));
    fs.writeFileSync(path.join(pkg, "cli.js"), "#!/usr/bin/env node\nprocess.exit(process.argv[2] === '--check' ? 0 : 1);\n");
    const archive = path.join(root, "fixture.tgz");
    await tar.c({ file: archive, gzip: true, cwd: root }, ["package"]);
    const installed = await prepareAgent(root, agent({ npx: { package: "codeaw-acp-fixture@1.0.0", args: [], env: {} } }), undefined, undefined, {
      run: (command, args, directory, signal, env) => runInstaller(command, [...args.slice(0, -1), archive], directory, signal, env),
    });
    await runInstaller(installed.config.command, ["--check"], installed.directory, new AbortController().signal, installed.config.env.PATH
      ? { ...process.env, ...installed.config.env } : undefined);
  });

  it("cleans up package failures and rejects package specs that could invoke a shell", async () => {
    const root = home();
    const run = vi.fn(async () => { throw new Error("fixture install failure"); });
    await expect(prepareAgent(root, agent({ npx: { package: "test@1.0.0", args: [], env: {} } }), undefined, undefined, { run })).rejects.toThrow(/fixture install failure/);
    expect(fs.readdirSync(path.join(root, "agents", "codex-acp"))).toEqual([]);
    await expect(prepareAgent(root, agent({ npx: { package: "test & echo injected", args: [], env: {} } }), undefined, undefined, { run })).rejects.toThrow(/invalid npm package/);
    expect(run).toHaveBeenCalledTimes(1);
  });

  it("keeps package-manager output out of errors and reports missing prerequisites", async () => {
    const directory = home();
    const signal = new AbortController().signal;
    await expect(runInstaller(process.execPath, ["-e", "console.error('synthetic-sensitive-output'); process.exit(1)"], directory, signal))
      .rejects.toThrow("Agent package installation failed. Check your connection and package-manager setup, then retry.");
    await expect(runInstaller("codeaw-missing-installer-fixture", [], directory, signal)).rejects.toThrow(/Install uv/);
  });

  it("cancels a running installer and waits for it to close", async () => {
    const controller = new AbortController();
    const pending = runInstaller(process.execPath, ["-e", "setInterval(() => {}, 1000)"], home(), controller.signal);
    controller.abort();
    await expect(pending).rejects.toThrow(/cancelled/);
  });

  it("registers an update while preserving comments, env, disabled state, cwd and other fields", () => {
    const file = config();
    const entry: InstalledAgent = { id: "codex", name: "Codex", version: "1.0.0", directory: path.dirname(file),
      config: { name: "Codex", command: "new-command", args: ["acp"], env: { TEST_VALUE: "default", NEW_DEFAULT: "yes" }, enabled: true } };
    registerInstalledAgent(file, entry);
    const loaded = loadConfig(file);
    expect(loaded.config.agents.codex).toMatchObject({ name: "My Codex", command: "new-command", args: ["acp"], enabled: false,
      env: { TEST_VALUE: "synthetic-value", NEW_DEFAULT: "yes" }, cwd: path.dirname(file) });
    const text = fs.readFileSync(file, "utf8");
    expect(text).toContain("# preserve this comment");
    expect(YAML.parse(text).custom).toEqual({ keep: true });
    registerInstalledAgent(file, { ...entry, id: "new-agent" });
    expect(loadConfig(file).config.agents["new-agent"].enabled).toBe(true);
  });
});

describe("background agent installer", () => {
  it("returns progress immediately, rejects overlapping work and commits only on success", async () => {
    const file = config();
    const entry = binary();
    let finish!: (value: InstalledAgent) => void;
    const commit = vi.fn(async () => undefined);
    const installer = new AgentInstaller(file, commit, { registry: async () => [entry], prepare: async (_home, _agent, progress) => {
      progress!("Downloading fixture");
      return new Promise((resolve) => { finish = resolve; });
    } });
    expect((await installer.list())[0]).toMatchObject({ id: "codex-acp", configured: true, supported: true });
    expect(JSON.stringify(await installer.list())).not.toContain("synthetic-value");
    expect((await installer.start("codex")).state).toBe("installing");
    expect(installer.getStatus().message).toBe("Downloading fixture");
    await expect(installer.start("codex")).rejects.toThrow(/already in progress/);
    finish({ id: "codex", name: entry.name, version: entry.version, directory: "fixture", config: { name: entry.name, command: "fixture", args: [], env: {}, enabled: true } });
    expect((await installer.wait()).state).toBe("succeeded");
    expect(commit).toHaveBeenCalledOnce();
  });

  it("reports failure, allows retry and aborts pending work when stopped", async () => {
    const prepare = vi.fn(async (_home, _agent, _progress, signal?: AbortSignal): Promise<InstalledAgent> => {
      if (prepare.mock.calls.length === 1) throw new Error("Fixture failure");
      return new Promise((_resolve, reject) => signal!.addEventListener("abort", () => reject(new Error("Cancelled")), { once: true }));
    });
    const commit = vi.fn(async () => undefined);
    const installer = new AgentInstaller(config(), commit, { registry: async () => [binary()], prepare });
    await installer.start("codex");
    expect(await installer.wait()).toMatchObject({ state: "failed", message: "Fixture failure" });
    await installer.start("codex");
    await installer.stop();
    expect(installer.getStatus()).toMatchObject({ state: "failed", message: "Agent installation cancelled" });
    expect(commit).not.toHaveBeenCalled();
  });

  it("does not start an installation when shutdown happens during catalog loading", async () => {
    let finish!: (agents: RegistryAgent[]) => void;
    const prepare = vi.fn();
    const installer = new AgentInstaller(config(), undefined, { registry: () => new Promise((resolve) => { finish = resolve; }), prepare });
    const pending = installer.start("codex");
    await installer.stop();
    finish([binary()]);
    await expect(pending).rejects.toThrow(/stopped/);
    expect(prepare).not.toHaveBeenCalled();
  });
});
