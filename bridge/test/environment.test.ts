import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { desktopEnvironment, resolveCommand } from "../src/util/environment.js";

const directories: string[] = [];
afterEach(() => {
  for (const directory of directories.splice(0)) fs.rmSync(directory, { recursive: true, force: true });
});

describe.skipIf(process.platform !== "win32")("Windows command discovery", () => {
  function fixture() {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-command-"));
    directories.push(directory);
    const executable = path.join(directory, "codeaw-fixture.CMD");
    fs.writeFileSync(executable, "@exit /b 0\r\n");
    return { directory, executable };
  }

  it("finds npm command shims when the inherited Path is copied and merged", () => {
    const { directory, executable } = fixture();
    const environment = desktopEnvironment({ Path: directory, Pathext: ".CMD" });
    expect(resolveCommand("codeaw-fixture", { ...environment })).toBe(executable);
    expect(resolveCommand("missing-fixture", environment)).toBeUndefined();
  });

  it("honors an explicit PATH override alongside the inherited Path", () => {
    const { directory, executable } = fixture();
    const environment = desktopEnvironment({ Path: path.join(directory, "missing"), PATH: directory, PATHEXT: ".CMD" });
    expect(resolveCommand("codeaw-fixture", environment)).toBe(executable);
  });
});
