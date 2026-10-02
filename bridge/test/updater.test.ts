import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { BridgeUpdater, downloadBridgeUpdate, newerBridgeRelease, parseBridgeRelease, updateTarget, verifiedBridgeInstaller } from "../src/updater.js";

const homes: string[] = [];
const payload = Buffer.from("synthetic bridge installer fixture");
const sha256 = crypto.createHash("sha256").update(payload).digest("hex");

function home() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-updater-test-"));
  homes.push(directory);
  return directory;
}
function manifest(channel: "release" | "nightly" = "nightly", version = "0.2.0", buildNumber = 42) {
  const tag = channel === "nightly" ? "nightly" : `v${version}`;
  const base = `https://github.com/AvianJay/codeaw/releases`;
  return { schemaVersion: 1, channel, version, buildNumber, releaseUrl: `${base}/tag/${tag}`, assets: {
    "windows-x64-setup": { url: `${base}/download/${tag}/codeaw-bridge-windows-x64-setup.exe`, sha256, size: payload.length },
    "windows-x64": { url: `${base}/download/${tag}/codeaw-bridge-windows-x64.zip`, sha256, size: payload.length },
    "linux-arm64-musl": { url: `${base}/download/${tag}/codeaw-bridge-linux-arm64-musl.tar.gz`, sha256, size: payload.length },
  } };
}
function updater(directory = home(), options: ConstructorParameters<typeof BridgeUpdater>[1] = {}) {
  return new BridgeUpdater(path.join(directory, "config.yaml"), {
    version: "0.2.0", buildNumber: 41, buildChannel: "nightly", target: "windows-x64", installation: () => directory, ...options,
  });
}
function mockDownloads(release = manifest()) {
  return vi.spyOn(globalThis, "fetch").mockImplementation(async (input) =>
    String(input).includes("bridge-update.json") ? new Response(JSON.stringify(release)) : new Response(payload));
}

afterEach(() => {
  vi.restoreAllMocks();
  for (const directory of homes.splice(0)) {
    expect(path.dirname(directory)).toBe(path.resolve(os.tmpdir()));
    expect(path.basename(directory)).toMatch(/^codeaw-updater-test-/);
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

describe("bridge update manifests", () => {
  it("detects newer nightlies at the same version and compares stable versions numerically", () => {
    const release = parseBridgeRelease(manifest(), "AvianJay/codeaw", "nightly");
    expect(newerBridgeRelease(release, "0.2.0", 41)).toBe(true);
    expect(newerBridgeRelease(release, "0.2.0", 42)).toBe(false);
    expect(newerBridgeRelease(release, "0.10.0", 1)).toBe(false);
    expect(newerBridgeRelease(release, "0.1.99", 1000)).toBe(true);
    expect(updateTarget("darwin", "arm64")).toBe("macos-arm64");
    expect(updateTarget("win32", "x64")).toBe("windows-x64");
  });

  it("rejects wrong channels, foreign downloads and malformed or unbounded manifests", () => {
    expect(() => parseBridgeRelease(manifest(), "AvianJay/codeaw", "release")).toThrow(/mismatch/);
    for (const bad of [
      { schemaVersion: 2 }, { buildNumber: 0 }, { releaseUrl: "https://example.com" },
      { assets: { "windows-x64-setup": { url: "https://github.com/evil/repo/releases/download/nightly/setup.exe", size: 1, sha256 } } },
      { assets: { "windows-x64-setup": { ...manifest().assets["windows-x64-setup"], size: 2 ** 30 } } },
      { assets: { "windows-x64-setup": { ...manifest().assets["windows-x64-setup"], sha256: "bad" } } },
    ]) expect(() => parseBridgeRelease({ ...manifest(), ...bad }, "AvianJay/codeaw", "nightly")).toThrow();
  });
});

describe("bridge updater", () => {
  it("checks without installing and prepares a verified installer only on request", async () => {
    const fetch = mockDownloads();
    const update = updater();
    expect(fetch).not.toHaveBeenCalled();
    expect(update.check().state).toBe("checking");
    const status = await update.wait();
    expect(status).toMatchObject({ state: "available", installedVersion: "0.2.0+41", updateAvailable: true, canInstall: true });
    expect(fetch).toHaveBeenCalledTimes(1);
    expect(String(fetch.mock.calls[0][0])).toMatch(/download\/nightly\/bridge-update.json\?t=/);
    expect(update.prepare("installer").state).toBe("downloading");
    const ready = await update.wait();
    expect(ready).toMatchObject({ state: "ready", kind: "installer", progress: 1 });
    expect(fs.readFileSync(ready.file!)).toEqual(payload);
    await update.stop();
    expect(fs.existsSync(ready.file!)).toBe(true); // The installer must survive the old runtime's exit.
  });

  it("persists channel selection and permits explicit channel changes to older builds", async () => {
    const directory = home();
    const update = updater(directory);
    expect(() => update.setChannel("invalid")).toThrow(/channel/);
    update.setChannel("release");
    const release = manifest("release", "0.1.0", 1);
    const fetch = mockDownloads(release);
    update.check();
    expect((await update.wait()).updateAvailable).toBe(true);
    expect(String(fetch.mock.calls[0][0])).toContain("latest/download/bridge-update.json");
    expect(updater(directory).getStatus().channel).toBe("release");
    expect(updater(directory, { buildChannel: "release" }).getStatus().channel).toBe("release");
    expect(fs.existsSync(path.join(directory, "config.yaml"))).toBe(false);
  });

  it("offers portable downloads for source installs and selects the exact musl build", async () => {
    mockDownloads();
    const update = updater(home(), { target: "linux-arm64-musl", installation: () => undefined });
    update.check();
    await update.wait();
    expect(() => update.prepare("installer")).toThrow(/portable/);
    update.prepare();
    const ready = await update.wait();
    expect(ready).toMatchObject({ state: "ready", canInstall: false, kind: "portable" });
    expect(ready.file).toMatch(/codeaw-bridge-linux-arm64-musl.tar.gz$/);
  });

  it("does not download an equal build and reports unsupported targets", async () => {
    mockDownloads(manifest("nightly", "0.2.0", 41));
    const current = updater();
    current.check();
    expect((await current.wait()).state).toBe("current");
    expect(() => current.prepare()).toThrow(/newer/);
    vi.restoreAllMocks();
    mockDownloads();
    const unsupported = updater(home(), { target: "linux-ia32", installation: () => undefined });
    unsupported.check();
    await unsupported.wait();
    expect(() => unsupported.prepare()).toThrow(/No portable/);
  });

  it("keeps operations exclusive and rejects channel changes during a download", async () => {
    let resolve!: (response: Response) => void;
    vi.spyOn(globalThis, "fetch").mockImplementation(() => new Promise<Response>(done => { resolve = done; }));
    const update = updater();
    update.check();
    expect(update.check().state).toBe("checking");
    expect(() => update.setChannel("release")).toThrow(/Wait/);
    expect(() => update.prepare()).toThrow(/Wait/);
    resolve(new Response(JSON.stringify(manifest())));
    await update.wait();
    update.prepare();
    expect(() => update.setChannel("release")).toThrow(/Wait/);
    expect(() => update.prepare()).toThrow(/Wait/);
    resolve(new Response(payload));
    expect((await update.wait()).state).toBe("ready");
  });

  it("clears stale release information and handles absent, malformed and oversized manifests", async () => {
    const fetch = mockDownloads();
    const update = updater();
    update.check(); await update.wait();
    for (const response of [new Response("", { status: 404 }), new Response("broken"), new Response("x".repeat(128 * 1024 + 1))]) {
      fetch.mockResolvedValueOnce(response);
      expect(update.check().release).toBeUndefined();
      expect(await update.wait()).toMatchObject({ state: "error", updateAvailable: false });
    }
    fetch.mockRejectedValueOnce(new Error("https://user:synthetic-secret@proxy.example"));
    update.check();
    expect((await update.wait()).message).not.toContain("synthetic-secret");
  });

  it("cancels in-flight downloads and removes partial files on shutdown", async () => {
    const fetch = mockDownloads();
    const update = updater();
    update.check(); await update.wait();
    fetch.mockImplementationOnce(async (_input, options) => {
      return await new Promise<Response>((_resolve, reject) => {
        options!.signal!.addEventListener("abort", () => reject(new Error("cancelled")), { once: true });
      });
    });
    update.prepare();
    await update.stop();
    expect(update.getStatus()).toMatchObject({ state: "error", file: undefined });
    expect(fs.readdirSync(path.join(path.dirname(update.file), "updates"))).toEqual([]);
    expect(() => update.prepare()).toThrow(/Wait/);
  });
});

describe("bridge download integrity", () => {
  it("blocks registered services and re-verifies a staged installer before handoff", async () => {
    mockDownloads();
    const directory = home();
    const update = updater(directory);
    update.check(); await update.wait();
    update.prepare("installer");
    const ready = await update.wait();
    const installation = () => directory;
    await expect(verifiedBridgeInstaller(update.file, ready, { installation, serviceInstalled: () => true })).rejects.toThrow(/registered Windows service/);
    const serviceInstalled = vi.fn(() => false);
    expect(await verifiedBridgeInstaller(update.file, ready, { installation, serviceInstalled })).toMatchObject({ directory, file: ready.file });
    expect(serviceInstalled).toHaveBeenCalledWith(update.file);
    fs.writeFileSync(ready.file!, Buffer.alloc(payload.length, 1));
    await expect(verifiedBridgeInstaller(update.file, ready, { installation, serviceInstalled })).rejects.toThrow(/SHA-256/);
    await expect(verifiedBridgeInstaller(update.file, { ...ready, kind: "portable" }, { installation, serviceInstalled })).rejects.toThrow(/No verified/);
  });

  it("removes hash failures, truncation and oversized responses without returning a staged file", async () => {
    const directory = home();
    const file = path.join(directory, "download.exe");
    const asset = manifest().assets["windows-x64-setup"];
    const fetch = vi.spyOn(globalThis, "fetch");
    for (const body of [Buffer.alloc(payload.length, 1), payload.subarray(0, 3), Buffer.concat([payload, payload])]) {
      fetch.mockResolvedValueOnce(new Response(body));
      await expect(downloadBridgeUpdate(asset, file, new AbortController().signal)).rejects.toThrow();
      expect(fs.existsSync(file)).toBe(false);
    }
    fetch.mockResolvedValueOnce(new Response(payload, { headers: { "Content-Length": "999" } }));
    await expect(downloadBridgeUpdate(asset, file, new AbortController().signal)).rejects.toThrow(/size mismatch/);
    expect(fs.existsSync(file)).toBe(false);
  });
});
