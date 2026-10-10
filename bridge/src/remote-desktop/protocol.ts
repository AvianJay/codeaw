import { z } from "zod";

export const modes = ["balanced", "smooth", "low", "onDemand"] as const;
export type DesktopMode = typeof modes[number];
export const profiles = {
  balanced: { fps: 15, longEdge: 1600, quality: 70, bytesPerSecond: 250_000 },
  smooth: { fps: 30, longEdge: 1920, quality: 70, bytesPerSecond: 500_000 },
  low: { fps: 2, longEdge: 960, quality: 45, bytesPerSecond: 16_000 },
  onDemand: { fps: 1, longEdge: 960, quality: 45, bytesPerSecond: 8_000 },
} satisfies Record<DesktopMode, Record<string, number>>;

export const SessionOptions = z.object({
  mode: z.enum(modes).default("balanced"), monitorId: z.string().max(128).optional(),
  privilege: z.enum(["user", "system"]).default("user"), fps: z.union([z.literal(30), z.literal(60)]).default(30),
}).strict();
export type SessionOptions = z.infer<typeof SessionOptions>;
const coordinate = z.number().finite().min(0).max(1);
export const Input = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("pointer"), x: coordinate, y: coordinate }),
  z.object({ kind: z.literal("button"), button: z.enum(["left", "right", "middle"]), down: z.boolean(), x: coordinate, y: coordinate }),
  z.object({ kind: z.literal("wheel"), delta: z.number().int().min(-1200).max(1200),
    deltaX: z.number().int().min(-1200).max(1200).default(0), x: coordinate, y: coordinate }),
  z.object({ kind: z.literal("key"), code: z.number().int().min(1).max(254), down: z.boolean() }),
  z.object({ kind: z.literal("text"), text: z.string().max(4096) }),
  z.object({ kind: z.literal("release") }), z.object({ kind: z.literal("sas") }),
]);

export interface Monitor { id: string; name: string; x: number; y: number; width: number; height: number; primary: boolean }
export interface NativeInfo { monitors: Monitor[]; smooth: boolean; hardware: boolean; state: string }
export interface Tile { x: number; y: number; width: number; height: number; offset: number; length: number }
export interface NativeFrame {
  width: number; height: number; sourceWidth: number; sourceHeight: number;
  tiles: Tile[]; full: boolean; cursor?: { x: number; y: number; visible: boolean };
}
export interface NativeReply { result: Record<string, any>; payload: Buffer }
export interface DesktopBackend {
  request(command: string, params?: Record<string, unknown>): Promise<NativeReply>;
  onEvent?: (event: Record<string, any>) => void;
  dispose(): Promise<void>;
}
export type BackendFactory = (privilege: "user" | "system") => DesktopBackend;
export class DesktopError extends Error {
  constructor(readonly status: number, readonly code: string, message: string) { super(message); }
}

/** One oversize frame can borrow against future budget; it can never grow a queue. */
export class FrameBudget {
  private balance: number;
  private last: number;
  constructor(readonly rate: number, readonly burst = 64 * 1024, now = Date.now()) { this.balance = burst; this.last = now; }
  delay(bytes: number, now = Date.now()): number {
    this.balance = Math.min(this.burst, this.balance + Math.max(0, now - this.last) * this.rate / 1000);
    this.last = now;
    return Math.max(0, Math.ceil((Math.min(bytes, this.burst) - this.balance) * 1000 / this.rate));
  }
  consume(bytes: number) { this.balance -= bytes; }
}

/** Binary wire packet: little-endian JSON length, UTF-8 metadata, JPEG tile bytes. */
export function framePacket(header: Record<string, unknown>, payload: Buffer): Buffer {
  const json = Buffer.from(JSON.stringify(header));
  const prefix = Buffer.allocUnsafe(4); prefix.writeUInt32LE(json.length);
  return Buffer.concat([prefix, json, payload]);
}
