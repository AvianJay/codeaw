import { afterEach, expect, it, vi } from "vitest";
import { PathGuard } from "../src/server/ext.js";
import type { ClientHandle } from "../src/session/manager.js";
import { TerminalManager } from "../src/terminal/manager.js";
import { spawnShell } from "../src/terminal/pty.js";

vi.mock("../src/terminal/pty.js", () => ({
  spawnShell: vi.fn(() => ({
    pty: { write: vi.fn(), resize: vi.fn(), kill: vi.fn() },
    shell: "test-shell", closed: Promise.resolve(),
  })),
}));

afterEach(() => { vi.useRealTimers(); vi.clearAllMocks(); });

it("retries terminal creation idempotently without sharing it with another device", async () => {
  const manager = new TerminalManager(new PathGuard(() => [process.cwd()], () => []));
  const viewer = { id: "viewer", notify: vi.fn(async () => {}) } as unknown as ClientHandle;
  const params = { cwd: process.cwd(), createNew: true, creationId: "lost-response" };
  const first = manager.open("owner", viewer, params);
  manager.removeClient(viewer);
  expect(manager.open("owner", viewer, params).terminalId).toBe(first.terminalId);
  expect(manager.list("owner").terminals).toHaveLength(1);
  expect(manager.list("owner").terminals[0].creationId).toBe(params.creationId);
  expect(manager.open("another-device", viewer, params).terminalId).not.toBe(first.terminalId);
  expect(() => manager.open("owner", viewer, { ...params, creationId: "" })).toThrow();
  expect(() => manager.open("owner", viewer, { ...params, creationId: "x".repeat(129) })).toThrow();
  await manager.dispose();
});

it("retains detached and disconnected shells past the old idle timeout until explicitly closed", async () => {
  vi.useFakeTimers();
  const manager = new TerminalManager(new PathGuard(() => [process.cwd()], () => []));
  const viewer = { id: "viewer", notify: vi.fn(async () => {}) } as unknown as ClientHandle;
  const detached = manager.open("owner", viewer, { cwd: process.cwd(), createNew: true });
  const disconnected = manager.open("owner", viewer, { cwd: process.cwd(), createNew: true });
  manager.detach("owner", viewer, detached.terminalId);
  manager.removeClient(viewer);
  await vi.advanceTimersByTimeAsync(24 * 60 * 60_000);
  expect(manager.list("owner").terminals.map((t) => t.terminalId)).toEqual([detached.terminalId, disconnected.terminalId]);
  const processes = vi.mocked(spawnShell).mock.results.map((r) => r.value.pty);
  for (const process of processes) expect(process.kill).not.toHaveBeenCalled();
  await manager.close("owner", detached.terminalId);
  expect(processes[0].kill).toHaveBeenCalledOnce();
  expect(processes[1].kill).not.toHaveBeenCalled();
  await manager.dispose();
  expect(processes[1].kill).toHaveBeenCalledOnce();
  expect(manager.list("owner").terminals).toEqual([]);
});

it("enforces the per-device limit and releases slots for exited terminals only when closed", async () => {
  const manager = new TerminalManager(new PathGuard(() => [process.cwd()], () => []));
  const viewer = { id: "viewer", notify: vi.fn(async () => {}) } as unknown as ClientHandle;
  const opened = Array.from({ length: 8 }, () => manager.open("owner", viewer, { cwd: process.cwd(), createNew: true }));
  expect(() => manager.open("owner", viewer, { cwd: process.cwd(), createNew: true })).toThrow();
  vi.mocked(spawnShell).mock.calls[0][4](7);
  expect(manager.list("owner").terminals[0]).toMatchObject({ exited: true, exitCode: 7 });
  expect(() => manager.open("owner", viewer, { cwd: process.cwd(), createNew: true })).toThrow();
  expect(manager.open("other-owner", viewer, { cwd: process.cwd(), createNew: true }).terminalId).toBeTruthy();
  await manager.close("owner", opened[0].terminalId);
  expect(manager.open("owner", viewer, { cwd: process.cwd(), createNew: true }).terminalId).not.toBe(opened[0].terminalId);
  await manager.dispose();
});
