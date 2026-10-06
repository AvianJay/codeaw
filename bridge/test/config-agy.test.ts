import { afterEach, expect, it, vi } from "vitest";
import { detectAgents } from "../src/config.js";
import * as environment from "../src/util/environment.js";

afterEach(() => vi.restoreAllMocks());

it("detects native AGY instead of Gemini CLI and prefers it over the standalone ACP binary", () => {
  vi.spyOn(environment, "resolveCommand").mockImplementation((name) =>
    ["agy", "gemini", "agy_acp_server.exe", "agy_acp_server.par"].includes(name) ? "/installed/" + name : undefined);
  expect(detectAgents()).toEqual({ antigravity: { name: "Antigravity CLI", command: "/installed/agy", args: [], env: {}, enabled: true, transport: "agy" } });
});

it("keeps standalone Antigravity ACP available when the native CLI is absent", () => {
  vi.spyOn(environment, "resolveCommand").mockImplementation((name) => /^agy_acp_server/.test(name) ? "/installed/" + name : undefined);
  const agents = detectAgents();
  expect(agents.antigravity.command).toMatch(/agy_acp_server/);
  expect(agents.antigravity.transport).toBeUndefined();
  expect(agents.gemini).toBeUndefined();
});
