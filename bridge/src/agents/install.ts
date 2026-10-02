import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { Readable, Transform } from "node:stream";
import { pipeline } from "node:stream/promises";
import spawn from "cross-spawn";
import * as tar from "tar";
import yauzl from "yauzl";
import YAML from "yaml";
import { ConfigSchema, loadConfig, type AgentConfig } from "../config.js";
import { isInside, realPath, writeFileAtomic } from "../util/paths.js";
import { configAgentId, distributionFor, fetchRegistry, platformTarget, type RegistryAgent } from "./registry.js";

const MAX_DOWNLOAD = 512 * 1024 * 1024;
const MAX_EXTRACTED = 2 * 1024 * 1024 * 1024;
export interface InstalledAgent { id: string; name: string; version: string; directory: string; config: AgentConfig }
export type InstallProgress = (message: string) => void;

/** Validate both Windows and Unix paths, even when extracting on the other OS. */
export function archivePath(root: string, name: string): string {
  if (!name || name.includes("\\") || name.includes(":") || name.includes("\0") || path.posix.isAbsolute(name)
    || name.split("/").includes("..")) throw new Error("Archive contains an unsafe path");
  const destination = path.resolve(root, name);
  if (!isInside(root, destination)) throw new Error("Archive contains an unsafe path");
  return destination;
}

async function extractZip(file: string, directory: string): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    yauzl.open(file, { lazyEntries: true, strictFileNames: true }, (error, zip) => {
      if (error || !zip) { reject(new Error("Cannot open agent ZIP archive")); return; }
      let total = 0;
      const fail = (error: unknown) => { zip.close(); reject(error); };
      zip.on("error", fail);
      zip.on("end", resolve);
      zip.on("entry", (entry: yauzl.Entry) => {
        void (async () => {
          const destination = archivePath(directory, entry.fileName);
          const mode = (entry.externalFileAttributes >>> 16) & 0xffff;
          if ((mode & 0xf000) === 0xa000) throw new Error("Archive contains a symbolic link");
          total += entry.uncompressedSize;
          if (total > MAX_EXTRACTED) throw new Error("Agent archive is too large");
          if (entry.fileName.endsWith("/")) fs.mkdirSync(destination, { recursive: true });
          else {
            fs.mkdirSync(path.dirname(destination), { recursive: true });
            const stream = await new Promise<Readable>((resolve, reject) => zip.openReadStream(entry,
              (error, stream) => error || !stream ? reject(new Error("Cannot read agent ZIP entry")) : resolve(stream)));
            await pipeline(stream, fs.createWriteStream(destination, { flags: "wx", mode: mode & 0o777 || 0o644 }));
          }
          zip.readEntry();
        })().catch(fail);
      });
      zip.readEntry();
    });
  });
}

export async function extractArchive(file: string, directory: string, format: "zip" | "tar"): Promise<void> {
  if (format === "zip") { await extractZip(file, directory); return; }
  let total = 0;
  let invalid = false;
  await tar.x({ file, cwd: directory, strict: true, filter: (name, entry) => {
    try { archivePath(directory, name); } catch { invalid = true; return false; }
    if (!("type" in entry) || !["File", "Directory"].includes(entry.type)) { invalid = true; return false; }
    total += entry.size;
    if (total > MAX_EXTRACTED) { invalid = true; return false; }
    return true;
  } });
  if (invalid) throw new Error("Agent archive contains unsafe entries or is too large");
}

async function download(url: string, file: string, sha256: string | undefined, signal: AbortSignal): Promise<void> {
  const response = await fetch(url, { signal: AbortSignal.any([signal, AbortSignal.timeout(300_000)]) });
  if (!response.ok || !response.body) throw new Error("Cannot download the agent archive");
  if (Number(response.headers.get("content-length")) > MAX_DOWNLOAD) throw new Error("Agent download is too large");
  let bytes = 0;
  const hash = crypto.createHash("sha256");
  const check = new Transform({ transform(chunk: Buffer, _encoding, callback) {
    bytes += chunk.length;
    if (bytes > MAX_DOWNLOAD) { callback(new Error("Agent download is too large")); return; }
    hash.update(chunk); callback(null, chunk);
  } });
  await pipeline(Readable.fromWeb(response.body as any), check, fs.createWriteStream(file, { flags: "wx" }), { signal });
  if (sha256 && hash.digest("hex") !== sha256.toLowerCase()) throw new Error("Agent download failed its SHA-256 check");
}

/** Package-manager diagnostics can contain credentials; never forward their output. */
export async function runInstaller(command: string, args: string[], directory: string, signal: AbortSignal,
  env: NodeJS.ProcessEnv = process.env): Promise<void> {
  signal.throwIfAborted();
  await new Promise<void>((resolve, reject) => {
    const child = spawn(command, args, { cwd: directory, env, windowsHide: true, stdio: "ignore", detached: process.platform !== "win32" });
    let failure: Error | undefined;
    const terminate = (message: string) => {
      failure = new Error(message);
      if (!child.pid) return;
      if (process.platform === "win32") spawnSync("taskkill", ["/pid", String(child.pid), "/T", "/F"], { windowsHide: true, stdio: "ignore" });
      else { try { process.kill(-child.pid, "SIGKILL"); } catch { child.kill("SIGKILL"); } }
    };
    const abort = () => terminate("Agent installation cancelled");
    signal.addEventListener("abort", abort, { once: true });
    const timer = setTimeout(() => terminate("Agent installation timed out. Try again."), 600_000);
    const cleanup = () => { clearTimeout(timer); signal.removeEventListener("abort", abort); };
    child.once("error", (error: NodeJS.ErrnoException) => {
      cleanup();
      reject(new Error(error.code === "ENOENT" ? `Install ${command === "npm" ? "Node.js with npm" : "uv"} and reopen codeaw before installing this agent.` : "Cannot run the agent installer"));
    });
    child.once("close", (code) => {
      cleanup();
      if (failure) reject(failure);
      else if (code === 0) resolve(); else reject(new Error("Agent package installation failed. Check your connection and package-manager setup, then retry."));
    });
  });
}

export interface InstallDependencies {
  run?: typeof runInstaller;
  download?: typeof download;
}

/** Each install gets a new directory, so failure cannot damage a working version. */
export async function prepareAgent(home: string, agent: RegistryAgent, progress: InstallProgress = () => undefined,
  signal: AbortSignal = new AbortController().signal, dependencies: InstallDependencies = {}): Promise<InstalledAgent> {
  const distribution = distributionFor(agent);
  if (!distribution) throw new Error(`This agent has no distribution for ${platformTarget()}`);
  const root = path.resolve(home, "agents", agent.id);
  fs.mkdirSync(root, { recursive: true });
  const directory = fs.mkdtempSync(path.join(root, "install-"));
  const run = dependencies.run ?? runInstaller;
  try {
    let command: string;
    const spec = distribution.spec;
    if (distribution.kind === "binary") {
      const binary = distribution.spec;
      const destination = archivePath(directory, binary.cmd.replace(/\\/g, "/").replace(/^\.\//, ""));
      const pathname = new URL(binary.archive).pathname.toLowerCase();
      if (/\.(tar\.bz2|tbz2|dmg|pkg|deb|rpm|msi|appimage)$/.test(pathname)) throw new Error("This agent uses an unsupported archive format");
      const format = pathname.endsWith(".zip") ? "zip" : /\.(tar\.gz|tgz|tar)$/.test(pathname) ? "tar" : undefined;
      progress("Downloading agent…");
      const archive = path.join(directory, "download.archive");
      await (dependencies.download ?? download)(binary.archive, archive, binary.sha256, signal);
      signal.throwIfAborted();
      if (format) { progress("Extracting agent…"); await extractArchive(archive, directory, format); fs.unlinkSync(archive); }
      else { fs.mkdirSync(path.dirname(destination), { recursive: true }); fs.renameSync(archive, destination); }
      command = destination;
      if (!isInside(directory, realPath(command)) || !fs.statSync(command).isFile()) throw new Error("Agent executable was not found in the download");
      if (process.platform !== "win32") fs.chmodSync(command, 0o755);
    } else if (distribution.kind === "npx") {
      const pkg = distribution.spec.package;
      const match = /^((?:@[a-z0-9_.-]+\/)?[a-z0-9_.-]+)(?:@[a-zA-Z0-9_.+-]+)?$/.exec(pkg);
      if (!match || pkg.startsWith(".")) throw new Error("Registry contains an invalid npm package");
      progress("Installing npm package…");
      await run("npm", ["install", "--prefix", directory, "--no-audit", "--no-fund", "--progress=false", "--", pkg], directory, signal);
      const pkgDir = path.join(directory, "node_modules", match[1]);
      const manifest = JSON.parse(fs.readFileSync(path.join(pkgDir, "package.json"), "utf8"));
      const name = match[1].split("/").at(-1)!;
      const bins: Record<string, string> = typeof manifest.bin === "string" ? { [name]: manifest.bin } : manifest.bin ?? {};
      const bin = bins[name] ? name : Object.keys(bins)[0];
      if (!bin || !/^[a-zA-Z0-9_.-]+$/.test(bin) || !isInside(pkgDir, realPath(path.resolve(pkgDir, bins[bin])))) throw new Error("Agent package has no valid executable");
      command = path.join(directory, "node_modules", ".bin", bin + (process.platform === "win32" ? ".cmd" : ""));
      if (!fs.existsSync(command)) throw new Error("Agent package executable was not installed");
    } else {
      const pkg = distribution.spec.package.replace(/^([a-zA-Z0-9_.-]+)@([a-zA-Z0-9_.+-]+)$/, "$1==$2");
      if (!/^[a-zA-Z0-9][a-zA-Z0-9_.-]*(?:==[a-zA-Z0-9_.+-]+)?$/.test(pkg)) throw new Error("Registry contains an invalid Python package");
      progress("Installing Python package…");
      const binDir = path.join(directory, "bin");
      await run("uv", ["tool", "install", "--no-progress", "--", pkg], directory, signal,
        { ...process.env, UV_TOOL_DIR: path.join(directory, "tools"), UV_TOOL_BIN_DIR: binDir });
      const name = pkg.split("==")[0];
      const bins = fs.readdirSync(binDir).filter((entry) => process.platform !== "win32" || entry.endsWith(".exe"));
      const bin = bins.find((entry) => entry === name || entry === name + ".exe") ?? (bins.length === 1 ? bins[0] : undefined);
      if (!bin) throw new Error("Python agent package has no unambiguous executable");
      command = path.join(binDir, bin);
    }
    signal.throwIfAborted();
    const result: InstalledAgent = { id: configAgentId(agent.id), name: agent.name, version: agent.version, directory,
      config: { name: agent.name, command, args: spec.args, env: spec.env, enabled: true,
        ...(distribution.kind === "binary" ? { cwd: directory } : {}) } };
    writeFileAtomic(path.join(directory, "installed.json"), JSON.stringify({ id: agent.id, version: agent.version }));
    return result;
  } catch (error) {
    // directory comes from mkdtemp inside the agent root, never from archive contents.
    if (isInside(root, directory) && directory !== root) fs.rmSync(directory, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
    throw error;
  }
}

/** Read the latest YAML at commit time, preserving comments and custom credentials/settings. */
export function registerInstalledAgent(file: string, installed: InstalledAgent): void {
  const current = loadConfig(file);
  const doc = YAML.parseDocument(fs.readFileSync(file, "utf8"));
  if (doc.errors.length) throw new Error("Config contains invalid YAML");
  const existing = Object.hasOwn(current.config.agents, installed.id) ? current.config.agents[installed.id] : undefined;
  if (existing) {
    doc.setIn(["agents", installed.id, "command"], installed.config.command);
    doc.setIn(["agents", installed.id, "args"], installed.config.args);
    if (!existing.cwd && installed.config.cwd) doc.setIn(["agents", installed.id, "cwd"], installed.config.cwd);
    for (const [key, value] of Object.entries(installed.config.env)) {
      if (!Object.hasOwn(existing.env, key)) doc.setIn(["agents", installed.id, "env", key], value);
    }
  } else doc.setIn(["agents", installed.id], installed.config);
  if (!ConfigSchema.safeParse(doc.toJSON()).success) throw new Error("Installation would create an invalid config");
  writeFileAtomic(file, doc.toString());
}

export interface InstallStatus {
  state: "idle" | "installing" | "succeeded" | "failed";
  message: string; agentId?: string; name?: string; version?: string;
}

/** Long installations run outside the IPC request; the tray polls short status requests. */
export class AgentInstaller {
  private catalog?: RegistryAgent[];
  private status: InstallStatus = { state: "idle", message: "" };
  private controller?: AbortController;
  private pending?: Promise<void>;
  private closed = false;

  constructor(private file: string, private commit: (agent: InstalledAgent) => Promise<void> = async (agent) => registerInstalledAgent(file, agent),
    private dependencies: { registry?: typeof fetchRegistry; prepare?: typeof prepareAgent } = {}) {}

  async list(refresh = false) {
    if (!this.catalog || refresh) this.catalog = await (this.dependencies.registry ?? fetchRegistry)();
    const configured = loadConfig(this.file).config.agents;
    return this.catalog.map((agent) => ({ id: agent.id, name: agent.name, version: agent.version, description: agent.description,
      configured: Object.hasOwn(configured, configAgentId(agent.id)), kind: distributionFor(agent)?.kind,
      supported: !!distributionFor(agent), target: platformTarget() }));
  }

  getStatus(): InstallStatus { return { ...this.status }; }

  async start(id: string): Promise<InstallStatus> {
    if (this.closed) throw new Error("ACP installer is stopped");
    if (this.getStatus().state === "installing") throw new Error("An agent installation is already in progress");
    if (!this.catalog) await this.list();
    // Recheck after the async catalog load to reject overlapping first requests.
    if (this.closed) throw new Error("ACP installer is stopped");
    if (this.status.state === "installing") throw new Error("An agent installation is already in progress");
    const agent = this.catalog!.find((agent) => agent.id === id || configAgentId(agent.id) === id);
    if (!agent) throw new Error("Unknown ACP registry agent. List agents first.");
    if (!distributionFor(agent)) throw new Error(`This agent has no distribution for ${platformTarget()}`);
    this.controller = new AbortController();
    this.status = { state: "installing", agentId: agent.id, name: agent.name, version: agent.version, message: "Preparing installation…" };
    this.pending = (async () => {
      try {
        const installed = await (this.dependencies.prepare ?? prepareAgent)(path.dirname(this.file), agent,
          (message) => { this.status.message = message; }, this.controller!.signal);
        await this.commit(installed);
        this.status = { ...this.status, state: "succeeded", message: "Agent installed. Restart the bridge to apply it." };
      } catch (error) {
        this.status = { ...this.status, state: "failed", message: error instanceof Error ? error.message : "Agent installation failed" };
      }
    })();
    return this.getStatus();
  }

  async wait(): Promise<InstallStatus> { await this.pending; return this.getStatus(); }
  async stop(): Promise<void> { this.closed = true; this.controller?.abort(); await this.pending; }
}
