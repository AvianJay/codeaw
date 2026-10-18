import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { launchWindowsProcess } from "../src/desktop/windows-launcher.js";

const homes: string[] = [];
afterEach(() => {
  vi.unstubAllEnvs();
  for (const home of homes.splice(0)) fs.rmSync(home, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
});

function fixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-launcher-test-"));
  homes.push(root);
  const home = path.join(root, "space's 中文 & directory");
  fs.mkdirSync(home);
  return { home, log: path.join(home, "bridge.log") };
}

describe.skipIf(process.platform !== "win32")("native Windows launcher", () => {
  it("preserves argv, cwd and environment and appends both output streams as UTF-8", async () => {
    const { home, log } = fixture();
    const result = path.join(home, "result.json");
    fs.writeFileSync(log, "synthetic previous connection log\n");
    vi.stubEnv("CODEAW_LAUNCHER_TEST", "synthetic-inherited-value");
    const args = ["", "space's 中文", 'quoted "argument"', "trailing slash\\", "& $() ` %PATH%", "line\nbreak"];
    const script = `import fs from 'node:fs';
      console.log('stdout 中文 fixture'); console.error('stderr fixture');
      fs.writeFileSync(process.argv[1], JSON.stringify({args:process.argv.slice(2),cwd:process.cwd(),marker:process.env.CODEAW_LAUNCHER_TEST}));`;
    expect(await launchWindowsProcess(process.execPath, ["--input-type=module", "-e", script, result, ...args], home, log)).toBeGreaterThan(0);
    await vi.waitFor(() => expect(fs.existsSync(result)).toBe(true));
    expect(JSON.parse(fs.readFileSync(result, "utf8"))).toEqual({ args, cwd: home, marker: "synthetic-inherited-value" });
    await vi.waitFor(() => expect(fs.readFileSync(log, "utf8")).toContain("stderr fixture"));
    expect(fs.readFileSync(log, "utf8")).toContain("synthetic previous connection log\nstdout 中文 fixture");
  });

  it("reports a missing executable and records a fresh diagnostic without copying arguments", async () => {
    const { home, log } = fixture();
    await expect(launchWindowsProcess(path.join(home, "absent.exe"), ["synthetic-private-argument"], home, log))
      .rejects.toThrow("Cannot create the background process (Windows error 2)");
    const diagnostic = fs.readFileSync(log, "utf8");
    expect(diagnostic).toContain("[launcher] create_process failed (Windows error 2)");
    expect(diagnostic).not.toContain("synthetic-private-argument");
  });

  it("reports log creation failures before launching the child", async () => {
    const { home } = fixture();
    await expect(launchWindowsProcess(process.execPath, ["-e", "process.exit(99)"], home, home))
      .rejects.toThrow("Cannot open the background log (Windows error 5)");
  });
});
