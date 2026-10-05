import { spawnSync } from "node:child_process";
import { setTimeout } from "node:timers/promises";

export async function createMacosDmg(stage, disk, {
  spawn = spawnSync, wait = setTimeout, report = (message) => process.stderr.write(message),
} = {}) {
  for (let attempt = 1; attempt <= 3; attempt++) {
    const result = spawn("hdiutil", ["create", "-ov", "-size", "512m", "-fs", "HFS+", "-format", "UDZO", "-volname", "codeaw", "-srcfolder", stage, disk], {
      stdio: ["ignore", "inherit", "pipe"], encoding: "utf8",
    });
    if (result.error) throw result.error;
    const error = result.stderr ?? "";
    if (error) report(error);
    if (result.status === 0) return;
    if (attempt === 3 || !/create failed - Resource busy/i.test(error)) {
      throw new Error(`hdiutil failed (${result.status})`);
    }
    report(`Disk image resources busy; retrying (${attempt}/3).\n`);
    await wait(attempt * 2000);
  }
}
