import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, expect, it, vi } from "vitest";
import { detectAgents, loadConfig, writeDefaultConfig } from "../src/config.js";
import * as environment from "../src/util/environment.js";

const homes: string[] = [];
afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllEnvs();
  for (const home of homes.splice(0)) {
    if (!path.resolve(home).startsWith(path.resolve(os.tmpdir()) + path.sep) || !path.basename(home).startsWith("codeaw-omp-config-")) throw new Error("Unsafe test cleanup path");
    fs.rmSync(home, { recursive: true, force: true });
  }
});

it("detects Oh My Pi on PATH and writes a usable native ACP starter config", () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-omp-config-"));
  homes.push(home);
  const command = path.join(home, "custom omp", "omp.exe");
  vi.spyOn(environment, "resolveCommand").mockImplementation((name) => name === "omp" ? command : undefined);
  const file = path.join(home, "config.yaml");
  expect(writeDefaultConfig(file)).toBe(true);
  const config = loadConfig(file).config;
  expect(config.agents).toEqual({ omp: { name: "Oh My Pi", command, args: ["acp"], env: {}, enabled: true } });
  expect(writeDefaultConfig(file)).toBe(false);
});

it.skipIf(process.platform !== "win32")("finds the standalone Windows installation outside PATH", () => {
  const local = path.join(os.tmpdir(), "omp local app data");
  vi.stubEnv("LOCALAPPDATA", local);
  const command = path.join(local, "omp", "omp.exe");
  vi.spyOn(environment, "resolveCommand").mockImplementation((name) => name === command ? command : undefined);
  expect(detectAgents()).toEqual({ omp: { name: "Oh My Pi", command, args: ["acp"], env: {}, enabled: true } });
});

it.skipIf(process.platform !== "win32")("prefers the user's PATH installation over the standalone Windows default", () => {
  const command = path.join(os.tmpdir(), "custom omp", "omp.cmd");
  const resolve = vi.spyOn(environment, "resolveCommand").mockImplementation((name) => name === "omp" ? command : undefined);
  expect(detectAgents().omp.command).toBe(command);
  expect(resolve.mock.calls.filter(([name]) => name.endsWith("omp.exe"))).toHaveLength(0);
});

it("does not add Oh My Pi when no executable is installed", () => {
  vi.spyOn(environment, "resolveCommand").mockReturnValue(undefined);
  expect(detectAgents()).toEqual({});
});
