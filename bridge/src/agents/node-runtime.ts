import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { Readable, Transform } from "node:stream";
import { pipeline } from "node:stream/promises";
import * as tar from "tar";
import { desktopEnvironment, resolveCommand } from "../util/environment.js";

export function nodeArchive(checksums: string, arch = process.arch): { name: string; sha256: string } {
  if (!["x64", "arm64"].includes(arch)) throw new Error("Unsupported macOS Node.js architecture");
  const pattern = new RegExp(`^([a-f0-9]{64})\\s+(node-v24\\.\\d+\\.\\d+-darwin-${arch}\\.tar\\.gz)$`, "m");
  const match = pattern.exec(checksums);
  if (!match) throw new Error("Cannot find a verified Node.js runtime for this Mac");
  return { name: match[2], sha256: match[1] };
}

export async function npmEnvironment(home: string, signal: AbortSignal, progress: (message: string) => void): Promise<NodeJS.ProcessEnv> {
  signal.throwIfAborted();
  const directory = path.join(home, "runtime", "node");
  const env = desktopEnvironment();
  const runtimeBin = path.join(directory, "bin");
  if (fs.existsSync(path.join(runtimeBin, "node"))) env.PATH = runtimeBin + path.delimiter + env.PATH;
  const npm = resolveCommand("npm", env);
  if (npm && spawnSync(npm, ["--version"], { env, timeout: 15_000, stdio: "ignore", windowsHide: true }).status === 0) return env;
  if (process.platform !== "darwin") throw new Error("Install Node.js with npm and reopen codeaw before installing this agent.");
  progress("Preparing a private Node.js runtime for ACP (your system Node.js is not changed)…");
  fs.mkdirSync(path.dirname(directory), { recursive: true });
  const stage = fs.mkdtempSync(path.join(path.dirname(directory), "node-install-"));
  try {
    const downloadSignal = AbortSignal.any([signal, AbortSignal.timeout(300_000)]);
    const base = "https://nodejs.org/dist/latest-v24.x/";
    const index = await fetch(base + "SHASUMS256.txt", { signal: downloadSignal });
    if (!index.ok) throw new Error("Cannot download the Node.js checksum index");
    const asset = nodeArchive(await index.text());
    const response = await fetch(base + asset.name, { signal: downloadSignal });
    if (!response.ok || !response.body) throw new Error("Cannot download the Node.js runtime");
    const archive = path.join(stage, "node.tar.gz");
    const hash = crypto.createHash("sha256");
    let bytes = 0;
    const check = new Transform({ transform(chunk: Buffer, _encoding, callback) {
      bytes += chunk.length;
      if (bytes > 128 * 1024 * 1024) { callback(new Error("Node.js download is too large")); return; }
      hash.update(chunk); callback(null, chunk);
    } });
    await pipeline(Readable.fromWeb(response.body as any), check, fs.createWriteStream(archive, { flags: "wx" }), { signal: downloadSignal });
    if (hash.digest("hex") !== asset.sha256) throw new Error("Node.js runtime failed its SHA-256 check");
    const payload = path.join(stage, "payload");
    fs.mkdirSync(payload);
    await tar.x({ file: archive, cwd: payload, strip: 1, strict: true });
    signal.throwIfAborted();
    const candidateEnv = { ...env, PATH: path.join(payload, "bin") + path.delimiter + env.PATH };
    if (spawnSync(path.join(payload, "bin/npm"), ["--version"], { env: candidateEnv, timeout: 15_000, stdio: "ignore" }).status !== 0) {
      throw new Error("The downloaded Node.js runtime cannot run on this Mac");
    }
    if (fs.existsSync(directory)) fs.renameSync(directory, path.join(stage, "previous"));
    try { fs.renameSync(payload, directory); }
    catch (error) { if (fs.existsSync(path.join(stage, "previous"))) fs.renameSync(path.join(stage, "previous"), directory); throw error; }
    return { ...env, PATH: runtimeBin + path.delimiter + env.PATH };
  } finally { fs.rmSync(stage, { recursive: true, force: true }); }
}
