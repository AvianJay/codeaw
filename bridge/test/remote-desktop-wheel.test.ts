import { afterEach, describe, expect, it } from "vitest";
import http from "node:http";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { once } from "node:events";
import { WebSocket } from "ws";
import { DeviceStore } from "../src/server/auth.js";
import { DesktopManager } from "../src/remote-desktop/manager.js";
import { Input, type DesktopBackend } from "../src/remote-desktop/protocol.js";

const wheel = { kind: "wheel", delta: 120, x: .5, y: .25 };
const cleanup: (() => Promise<void>)[] = [];
afterEach(async () => { for (const close of cleanup.splice(0).reverse()) await close(); });

async function connectedDesktop() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-wheel-test-"));
  const devices = new DeviceStore(directory);
  const token = "wheel-test-device-token";
  const device = devices.addDeviceWithToken("Wheel test", token);
  const inputs: Record<string, unknown>[] = [];
  const backend: DesktopBackend = {
    async request(command, params = {}) {
      if (command === "input") inputs.push(params.input as Record<string, unknown>);
      const result = command === "info" ? { monitors: [{ id: "monitor", primary: true }] }
        : command === "capture" ? { width: 1, height: 1, sourceWidth: 1, sourceHeight: 1,
          full: true, tiles: [{ x: 0, y: 0, width: 1, height: 1, offset: 0, length: 1 }] } : {};
      return { result, payload: command === "capture" ? Buffer.from([0]) : Buffer.alloc(0) };
    },
    async dispose() {},
  };
  const manager = new DesktopManager({ devices, enabled: () => true, available: () => true, backendFactory: () => backend });
  const server = http.createServer();
  server.on("upgrade", (req, socket, head) => manager.onUpgrade(req, socket, head, new URL(req.url!, "http://localhost")));
  cleanup.push(async () => {
    await manager.dispose();
    await new Promise<void>((resolve) => server.close(() => resolve()));
    if (!path.resolve(directory).startsWith(path.join(os.tmpdir(), "codeaw-wheel-test-"))) throw new Error("Invalid test directory");
    fs.rmSync(directory, { recursive: true, force: true });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const session = await manager.create(device.id, token, {});
  const ws = new WebSocket(`ws://127.0.0.1:${(server.address() as { port: number }).port}${session.socketPath}`);
  ws.on("error", () => undefined);
  let active = false;
  const messages: Record<string, unknown>[] = [];
  ws.on("message", (bytes, binary) => {
    if (binary) {
      const packet = Buffer.from(bytes as Buffer);
      const frame = JSON.parse(packet.subarray(4, 4 + packet.readUInt32LE(0)).toString());
      ws.send(JSON.stringify({ type: "ack", epoch: frame.epoch, seq: frame.seq }));
    } else {
      const message = JSON.parse(bytes.toString());
      messages.push(message);
      if (message.state === "active") active = true;
    }
  });
  await once(ws, "open");
  ws.send(JSON.stringify({ type: "auth", ticket: session.ticket }));
  await expect.poll(() => active).toBe(true);
  return { ws, inputs, messages, send: (input: unknown) => ws.send(JSON.stringify({ type: "input", epoch: 1, input })) };
}

describe("remote desktop wheel input", () => {
  it("keeps vertical-only clients compatible and defaults the horizontal axis to zero", () => {
    expect(Input.parse(wheel)).toEqual({ ...wheel, deltaX: 0 });
  });

  it.each([-1200, -120, 0, 120, 1200])("preserves signed horizontal delta %s", (deltaX) => {
    expect(Input.parse({ ...wheel, deltaX })).toEqual({ ...wheel, deltaX });
  });

  it.each([-1201, 1201, .5, NaN, Infinity, "120", null])("rejects invalid horizontal delta %s", (deltaX) => {
    expect(Input.safeParse({ ...wheel, deltaX }).success).toBe(false);
  });

  it("forwards both scroll axes and legacy input through an authenticated session", async () => {
    const h = await connectedDesktop();
    h.send(wheel);
    h.send({ ...wheel, delta: 0, deltaX: 120 });
    h.send({ ...wheel, delta: -240, deltaX: -120 });
    await expect.poll(() => h.inputs).toEqual([
      { ...wheel, deltaX: 0 },
      { ...wheel, delta: 0, deltaX: 120 },
      { ...wheel, delta: -240, deltaX: -120 },
    ]);
  });

  it("rejects an out-of-range horizontal axis before it reaches the native backend", async () => {
    const h = await connectedDesktop();
    h.send({ ...wheel, deltaX: 1201 });
    await expect.poll(() => h.ws.readyState).toBe(WebSocket.CLOSED);
    expect(h.inputs).toEqual([]);
    expect(h.messages).toContainEqual(expect.objectContaining({ type: "error", code: "invalid_input" }));
  });
});
