import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { execFile, spawnSync } from "node:child_process";
import { promisify } from "node:util";
import { Readable, Transform } from "node:stream";
import { pipeline } from "node:stream/promises";
import { z } from "zod";
import { BUILD_NUMBER, BUILD_TARGET, UPDATE_CHANNEL, UPDATE_REPOSITORY, VERSION } from "./version.js";
import { bridgeInvocation } from "./desktop/process.js";
import { requestControl, runningStatus } from "./desktop/control.js";
import { serviceName } from "./desktop/service.js";
import { defaultConfigFile } from "./config.js";
import { isInside, readJson, realPath, writeFileAtomic } from "./util/paths.js";

export type UpdateChannel = "release" | "nightly";
export type UpdateKind = "installer" | "portable";
const MAX_DOWNLOAD = 512 * 1024 * 1024;
const AssetSchema = z.object({ url: z.url(), sha256: z.string().regex(/^[a-f0-9]{64}$/i), size: z.number().int().positive().max(MAX_DOWNLOAD) });
const ReleaseSchema = z.object({
  schemaVersion: z.literal(1), channel: z.enum(["release", "nightly"]),
  version: z.string().regex(/^\d+\.\d+\.\d+$/), buildNumber: z.number().int().positive().max(Number.MAX_SAFE_INTEGER),
  releaseUrl: z.url(), assets: z.record(z.string(), AssetSchema),
});
export type BridgeRelease = z.infer<typeof ReleaseSchema>;
export type UpdateAsset = z.infer<typeof AssetSchema>;

export function updateTarget(platform: string = process.platform, arch: string = process.arch): string {
  return `${platform === "win32" ? "windows" : platform === "darwin" ? "macos" : platform}-${arch}`;
}

export function parseBridgeRelease(input: unknown, repository: string, channel: UpdateChannel): BridgeRelease {
  const parsed = ReleaseSchema.safeParse(input);
  if (!parsed.success) throw new Error("Invalid bridge update manifest");
  const release = parsed.data;
  const tag = channel === "nightly" ? "nightly" : `v${release.version}`;
  const base = `https://github.com/${repository}/releases`;
  if (release.channel !== channel || release.releaseUrl !== `${base}/tag/${tag}`) throw new Error("Bridge update channel or repository mismatch");
  for (const [target, asset] of Object.entries(release.assets)) {
    if (!/^(windows-(x64|arm64)(-setup)?|(linux|macos)-(x64|arm64)(-musl)?)$/.test(target)) throw new Error("Invalid bridge update target");
    const suffix = target.endsWith("-setup") ? ".exe" : target.startsWith("windows-") ? ".zip" : ".tar.gz";
    if (asset.url !== `${base}/download/${tag}/codeaw-bridge-${target}${suffix}`) throw new Error("Invalid bridge update download URL");
    asset.sha256 = asset.sha256.toLowerCase();
  }
  return release;
}

export function newerBridgeRelease(release: BridgeRelease, version: string, build: number): boolean {
  const next = release.version.split(".").map(Number);
  const current = version.split(".").map(Number);
  for (let i = 0; i < 3; i++) { if (next[i] !== current[i]) return next[i] > current[i]; }
  return release.buildNumber > build;
}

/** Stream to a fresh file; an oversized, truncated or corrupt payload is never handed to an installer. */
export async function downloadBridgeUpdate(asset: UpdateAsset, file: string, signal: AbortSignal,
  progress: (value: number) => void = () => undefined): Promise<void> {
  const bounded = AbortSignal.any([signal, AbortSignal.timeout(300_000)]);
  const response = await fetch(asset.url, { signal: bounded, headers: { "Cache-Control": "no-cache" } });
  if (!response.ok || !response.body) throw new Error("Cannot download the bridge update. Check your connection and retry.");
  const length = response.headers.get("content-length");
  if (length !== null && Number(length) !== asset.size) {
    await response.body.cancel();
    throw new Error("Bridge update size mismatch. Check for updates again and retry.");
  }
  let bytes = 0;
  const hash = crypto.createHash("sha256");
  const check = new Transform({ transform(chunk: Buffer, _encoding, callback) {
    bytes += chunk.length;
    if (bytes > asset.size || bytes > MAX_DOWNLOAD) { callback(new Error("Bridge update exceeds its expected size")); return; }
    hash.update(chunk); progress(bytes / asset.size); callback(null, chunk);
  } });
  try {
    await pipeline(Readable.fromWeb(response.body as any), check, fs.createWriteStream(file, { flags: "wx", mode: 0o600 }), { signal: bounded });
    if (bytes !== asset.size || hash.digest("hex") !== asset.sha256.toLowerCase()) throw new Error("Bridge update failed its size or SHA-256 check. Check for updates again and retry.");
  } catch (error) {
    fs.rmSync(file, { force: true });
    throw error;
  }
}

export interface UpdaterOptions {
  version?: string; buildNumber?: number; buildChannel?: UpdateChannel; repository?: string; target?: string;
  installation?: () => string | undefined;
}
export interface BridgeUpdateStatus {
  state: "idle" | "checking" | "available" | "current" | "downloading" | "ready" | "error";
  channel: UpdateChannel; buildChannel: UpdateChannel; installedVersion: string; target: string;
  canInstall: boolean; releaseUrl: string; release?: BridgeRelease; updateAvailable: boolean;
  checkedAt?: string; progress?: number; file?: string; kind?: UpdateKind; message: string;
}

/** Only an installed standalone Windows bridge can invoke NSIS against its current directory. */
export function bridgeInstallation(): string | undefined {
  if (process.platform !== "win32") return;
  const invocation = bridgeInvocation();
  if (invocation.args.length) return;
  const directory = path.dirname(invocation.executable);
  if (fs.existsSync(path.join(directory, "uninstall.exe")) && fs.existsSync(path.join(directory, "launch.ps1"))) return directory;
}

export class BridgeUpdater {
  readonly version: string;
  readonly buildNumber: number;
  readonly buildChannel: UpdateChannel;
  readonly repository: string;
  readonly target: string;
  private readonly preferences: string;
  private readonly installation: () => string | undefined;
  private channel: UpdateChannel;
  private status: Pick<BridgeUpdateStatus, "state" | "message" | "release" | "checkedAt" | "progress" | "file" | "kind"> = { state: "idle", message: "Check for bridge updates." };
  private pending?: Promise<void>;
  private controller?: AbortController;
  private stopped = false;

  constructor(readonly file: string, options: UpdaterOptions = {}) {
    this.version = options.version ?? VERSION;
    this.buildNumber = options.buildNumber ?? BUILD_NUMBER;
    this.buildChannel = options.buildChannel ?? UPDATE_CHANNEL;
    this.repository = options.repository ?? UPDATE_REPOSITORY;
    this.target = options.target ?? (BUILD_TARGET || updateTarget());
    this.installation = options.installation ?? bridgeInstallation;
    if (!/^[\w.-]+\/[\w.-]+$/.test(this.repository)) throw new Error("Invalid bridge update repository");
    this.preferences = path.join(path.dirname(file), `bridge-update-${this.buildChannel}.json`);
    const saved = readJson<{ channel?: string } | null>(this.preferences, null)?.channel;
    this.channel = saved === "release" || saved === "nightly" ? saved : this.buildChannel;
  }

  getStatus(): BridgeUpdateStatus {
    const release = this.status.release;
    return { ...this.status, channel: this.channel, buildChannel: this.buildChannel,
      installedVersion: `${this.version}+${this.buildNumber}`, target: this.target,
      canInstall: !!this.installation(), releaseUrl: release?.releaseUrl ??
        `https://github.com/${this.repository}/releases/${this.channel === "nightly" ? "tag/nightly" : "latest"}`,
      updateAvailable: !!release && (this.channel !== this.buildChannel || newerBridgeRelease(release, this.version, this.buildNumber)) };
  }

  private busy(): boolean { return this.status.state === "checking" || this.status.state === "downloading"; }

  setChannel(value: unknown): BridgeUpdateStatus {
    if (value !== "release" && value !== "nightly") throw new Error("Unknown bridge update channel");
    if (this.busy() || this.stopped) throw new Error("Wait for the current bridge update operation to finish");
    if (value !== this.channel) {
      writeFileAtomic(this.preferences, JSON.stringify({ channel: value }));
      this.channel = value;
      this.status = { state: "idle", message: "Channel changed. Check for updates." };
    }
    return this.getStatus();
  }

  check(): BridgeUpdateStatus {
    if (this.busy() || this.stopped) return this.getStatus();
    this.status = { state: "checking", message: "Checking for bridge updates…" };
    this.controller = new AbortController();
    const signal = AbortSignal.any([this.controller.signal, AbortSignal.timeout(20_000)]);
    const route = this.channel === "nightly" ? "download/nightly" : "latest/download";
    const url = `https://github.com/${this.repository}/releases/${route}/bridge-update.json?t=${Date.now()}`;
    this.pending = (async () => {
      try {
        const response = await fetch(url, { signal, headers: { "Cache-Control": "no-cache" } });
        if (response.status === 404) throw new Error(`No bridge update manifest is published for ${this.channel} yet.`);
        if (!response.ok || !response.body) throw new Error("Cannot check for bridge updates. Check your connection and retry.");
        const chunks: Buffer[] = [];
        let size = 0;
        for await (const chunk of Readable.fromWeb(response.body as any)) {
          size += chunk.length;
          if (size > 128 * 1024) throw new Error("Bridge update manifest is too large");
          chunks.push(Buffer.from(chunk));
        }
        const release = parseBridgeRelease(JSON.parse(Buffer.concat(chunks).toString("utf8")), this.repository, this.channel);
        const available = this.channel !== this.buildChannel || newerBridgeRelease(release, this.version, this.buildNumber);
        this.status = { state: available ? "available" : "current", release, checkedAt: new Date().toISOString(),
          message: available ? `Bridge ${release.version}+${release.buildNumber} is available.` : "Bridge is up to date." };
      } catch (error) { this.fail(error, "Cannot check for bridge updates. Check your connection and retry."); }
    })();
    return this.getStatus();
  }

  prepare(kind: unknown = this.installation() ? "installer" : "portable"): BridgeUpdateStatus {
    if (this.busy() || this.stopped) throw new Error("Wait for the current bridge update operation to finish");
    if (kind !== "installer" && kind !== "portable") throw new Error("Unknown bridge update download kind");
    const status = this.getStatus();
    if (!status.updateAvailable || !status.release) throw new Error("Check for a newer bridge release first");
    if (kind === "installer" && !status.canInstall) throw new Error("Use the portable download for this bridge installation");
    const asset = status.release.assets[this.target + (kind === "installer" ? "-setup" : "")];
    if (!asset) throw new Error(`No ${kind} update is published for ${this.target}`);
    this.status = { state: "downloading", message: "Downloading and verifying the bridge update…", release: status.release, checkedAt: status.checkedAt, progress: 0, kind };
    this.controller = new AbortController();
    const signal = this.controller.signal;
    this.pending = (async () => {
      let directory: string | undefined;
      const root = path.resolve(path.dirname(this.file), "updates");
      try {
        fs.mkdirSync(root, { recursive: true, mode: 0o700 });
        directory = fs.mkdtempSync(path.join(root, "bridge-"));
        const file = path.join(directory, path.posix.basename(new URL(asset.url).pathname));
        await downloadBridgeUpdate(asset, file, signal, (progress) => { this.status.progress = progress; });
        this.status = { ...this.status, state: "ready", file, progress: 1,
          message: kind === "installer" ? "Update verified. Run the installer to finish updating; active turns will stop." : `Update verified. Extract ${file} and replace the bridge and web folder after stopping the bridge.` };
      } catch (error) {
        // Only the private directory returned by mkdtemp is removed on failure.
        if (directory && path.dirname(path.resolve(directory)) === root && isInside(realPath(root), realPath(directory))) {
          fs.rmSync(directory, { recursive: true, force: true });
        }
        this.fail(error, "Bridge update download failed. Check for updates again and retry.");
      }
    })();
    return this.getStatus();
  }

  private fail(error: unknown, fallback: string): void {
    // Network/runtime errors may contain credentials or URLs from proxy settings.
    const message = error instanceof Error && /^(Invalid bridge|Bridge update|Cannot (check|download)|No bridge)/.test(error.message) ? error.message : fallback;
    this.status = { ...this.status, state: "error", progress: undefined, file: undefined, message };
  }

  async wait(): Promise<BridgeUpdateStatus> { await this.pending; return this.getStatus(); }
  async stop(): Promise<void> { this.stopped = true; this.controller?.abort(); await this.pending; }
}

export interface InstallerChecks {
  installation?: () => string | undefined;
  serviceInstalled?: (config: string) => boolean;
}

export async function verifiedBridgeInstaller(file: string, status: BridgeUpdateStatus, checks: InstallerChecks = {}): Promise<{ file: string; directory: string; stopCustomProfile: boolean }> {
  const directory = (checks.installation ?? bridgeInstallation)();
  if (!directory || status.state !== "ready" || status.kind !== "installer" || !status.file || !status.release) throw new Error("No verified bridge installer is ready");
  const serviceInstalled = checks.serviceInstalled ?? ((config: string) => {
    const service = spawnSync("sc.exe", ["query", serviceName(config)], { windowsHide: true, stdio: "ignore", timeout: 5000 });
    if (service.error || (service.status !== 0 && service.status !== 1060)) throw new Error("Cannot verify Windows service status before updating.");
    return service.status === 0;
  });
  for (const config of new Set([file, defaultConfigFile()])) {
    if (serviceInstalled(config)) throw new Error("Remove the registered Windows service from an administrator terminal before updating.");
  }
  const asset = status.release.assets[`${status.target}-setup`];
  // Verify again at handoff in case the staged file changed after download.
  if (!asset || fs.statSync(status.file).size !== asset.size) throw new Error("Bridge update failed its size check");
  const hash = crypto.createHash("sha256");
  for await (const chunk of fs.createReadStream(status.file)) hash.update(chunk);
  if (hash.digest("hex") !== asset.sha256) throw new Error("Bridge update failed its SHA-256 check");
  return { file: status.file, directory, stopCustomProfile: path.resolve(file).toLowerCase() !== path.resolve(defaultConfigFile()).toLowerCase() };
}

/** Run in the caller's desktop session, after verification and an explicit install action. */
export async function installBridgeUpdate(file: string, status: BridgeUpdateStatus): Promise<void> {
  const installer = await verifiedBridgeInstaller(file, status);
  const quote = (value: string) => "'" + value.replace(/'/g, "''") + "'";
  const script = `$ErrorActionPreference = 'Stop'; Start-Process -FilePath ${quote(installer.file)} -ArgumentList ${quote(`/D=${installer.directory}`)}`;
  // Start-Process escapes Bun's child job so the installer survives the old bridge's exit.
  await promisify(execFile)("powershell.exe", ["-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-EncodedCommand",
    Buffer.from(script, "utf16le").toString("base64")], { windowsHide: true, timeout: 15_000 });
  // NSIS stops the default profile when installation begins. Custom profiles need a local stop too.
  if (installer.stopCustomProfile && await runningStatus(file)) {
    await requestControl(file, { command: "stop" });
  }
}
