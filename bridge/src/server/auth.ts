import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { readJson, writeFileAtomic } from "../util/paths.js";

export interface Device {
  id: string;
  name: string;
  tokenHash: string;
  createdAt: string;
  lastSeenAt?: string;
}

interface PairingCode {
  codeHash: string;
  expiresAt: number;
}

const PAIRING_TTL_MS = 5 * 60_000;
// Crockford-ish alphabet without look-alikes (0/O, 1/I/L).
const ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";

function sha256(s: string): string {
  return crypto.createHash("sha256").update(s).digest("hex");
}

export function normalizeCode(code: string): string {
  return code.toUpperCase().replace(/[^A-Z0-9]/g, "");
}

export function formatCode(code: string): string {
  return `${code.slice(0, 4)}-${code.slice(4)}`;
}

/**
 * Devices (`devices.json`) and pending pairing codes (`pairing.json`) live in the codeaw
 * home directory. Pairing codes are written by the CLI and consumed by the server, so
 * creating one only requires access to the user's files — not to a network endpoint.
 * Only SHA-256 hashes of tokens and codes are stored.
 */
export class DeviceStore {
  private readonly devicesFile: string;
  private readonly pairingFile: string;
  private cache?: { mtimeMs: number; devices: Device[] };
  private lastSeenWrites = new Map<string, number>();
  private failures: number[] = [];

  constructor(home: string) {
    this.devicesFile = path.join(home, "devices.json");
    this.pairingFile = path.join(home, "pairing.json");
  }

  list(): Device[] {
    let mtimeMs = 0;
    try {
      mtimeMs = fs.statSync(this.devicesFile).mtimeMs;
    } catch {
      return [];
    }
    if (!this.cache || this.cache.mtimeMs !== mtimeMs) {
      this.cache = { mtimeMs, devices: readJson<Device[]>(this.devicesFile, []) };
    }
    return this.cache.devices;
  }

  private save(devices: Device[]): void {
    writeFileAtomic(this.devicesFile, JSON.stringify(devices, null, 1));
    this.cache = undefined;
  }

  /** Returns the device owning `token`, or undefined. Constant-time per comparison. */
  authenticate(token: string | undefined): Device | undefined {
    if (!token) return undefined;
    const hash = Buffer.from(sha256(token), "hex");
    const device = this.list().find((d) => {
      const other = Buffer.from(d.tokenHash, "hex");
      return other.length === hash.length && crypto.timingSafeEqual(other, hash);
    });
    if (device) this.touch(device);
    return device;
  }

  private touch(device: Device): void {
    const now = Date.now();
    if (now - (this.lastSeenWrites.get(device.id) ?? 0) < 10 * 60_000) return;
    this.lastSeenWrites.set(device.id, now);
    const devices = this.list().map((d) => (d.id === device.id ? { ...d, lastSeenAt: new Date(now).toISOString() } : d));
    try {
      this.save(devices);
    } catch {
      // best effort
    }
  }

  revoke(idOrName: string): boolean {
    const devices = this.list();
    const kept = devices.filter((d) => d.id !== idOrName && d.name !== idOrName);
    if (kept.length === devices.length) return false;
    this.save(kept);
    return true;
  }

  /** Creates a fresh single-use code (valid 5 minutes) and returns it in plain text. */
  createPairingCode(now = Date.now()): string {
    const bytes = crypto.randomBytes(8);
    let code = "";
    for (const b of bytes) code += ALPHABET[b % ALPHABET.length];
    const codes = readJson<PairingCode[]>(this.pairingFile, []).filter((c) => c.expiresAt > now);
    codes.push({ codeHash: sha256(code), expiresAt: now + PAIRING_TTL_MS });
    writeFileAtomic(this.pairingFile, JSON.stringify(codes));
    return code;
  }

  /** Too many wrong codes in a minute locks pairing for that minute. */
  private rateLimited(now: number): boolean {
    this.failures = this.failures.filter((t) => now - t < 60_000);
    return this.failures.length >= 10;
  }

  /** Consumes a pairing code and registers a device. Returns the new device token. */
  pair(code: string, deviceName: string, now = Date.now()): { device: Device; token: string } | { error: string; status: number } {
    if (this.rateLimited(now)) return { error: "Too many attempts, wait a minute", status: 429 };
    const hash = sha256(normalizeCode(code));
    const codes = readJson<PairingCode[]>(this.pairingFile, []).filter((c) => c.expiresAt > now);
    const match = codes.find((c) => c.codeHash === hash);
    if (!match) {
      this.failures.push(now);
      writeFileAtomic(this.pairingFile, JSON.stringify(codes));
      return { error: "Invalid or expired pairing code", status: 403 };
    }
    writeFileAtomic(this.pairingFile, JSON.stringify(codes.filter((c) => c !== match)));
    const token = crypto.randomBytes(32).toString("hex");
    const name = deviceName.trim().slice(0, 60) || "device";
    const device: Device = {
      id: "d_" + crypto.randomBytes(5).toString("hex"),
      name,
      tokenHash: sha256(token),
      createdAt: new Date(now).toISOString(),
    };
    this.save([...this.list(), device]);
    return { device, token };
  }

  /** Test/dev helper: registers a device with a known token. */
  addDeviceWithToken(name: string, token: string): Device {
    const device: Device = { id: "d_" + crypto.randomBytes(5).toString("hex"), name, tokenHash: sha256(token), createdAt: new Date().toISOString() };
    this.save([...this.list(), device]);
    return device;
  }
}
