// Smoke a packaged executable, including its self-relaunch path, without touching the user's config.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const executable = path.resolve(process.argv[2] ?? "dist/bin/codeaw-bridge");
const home = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-binary-smoke-"));
const file = path.join(home, "config.yaml");
fs.writeFileSync(file, "listen:\n  hosts: [127.0.0.1]\n  port: 0\nagents: {}\n");
const exec = promisify(execFile);
const cli = async (...args) => {
  try { return (await exec(executable, [...args, "--config", file], { windowsHide: true, timeout: 20_000 })).stdout; }
  catch { throw new Error(`Packaged bridge command failed: ${args[0]}`); }
};
try {
  if (!(await cli("--help")).includes("service <action>")) throw new Error("Missing service CLI");
  await cli("start", "--background");
  const status = await cli("status");
  if (!status.includes("running")) throw new Error("Packaged background bridge is not running");
  await cli("start", "--background");
  const duplicate = await cli("status");
  if (status.match(/PID (\d+)/)?.[1] !== duplicate.match(/PID (\d+)/)?.[1]) throw new Error("Duplicate background process");
  await cli("restart");
  if (!(await cli("status")).includes("running")) throw new Error("Packaged restart failed");
  process.stdout.write("Packaged background start, duplicate start, status and restart passed.\n");
} finally {
  await cli("stop");
  if (!(await cli("status")).includes("stopped")) throw new Error("Packaged stop failed");
  fs.rmSync(home, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
}
