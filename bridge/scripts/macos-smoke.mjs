import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { controlAddress } from "../dist/desktop/control.js";

if (process.platform !== "darwin") throw new Error("macOS menu bar smoke requires macOS");
const executable = path.resolve(process.argv[2] ?? "dist/bin/codeaw-bridge");
const helper = path.join(path.dirname(executable), "codeaw-menu");
const directory = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-macos-smoke-"));
const file = path.join(directory, "config.yaml");
fs.writeFileSync(file, "listen:\n  hosts: [127.0.0.1]\n  port: 0\nagents: {}\n");
fs.writeFileSync(path.join(directory, "devices.json"), JSON.stringify([{ id: "d_smoke", name: "Smoke phone", tokenHash: "0".repeat(64), createdAt: new Date().toISOString() }]));
const exec = promisify(execFile);
const cli = async (...args) => (await exec(executable, [...args, "--config", file], { timeout: 20_000 })).stdout;
async function menus() {
  const output = (await exec("ps", ["-axo", "pid=,command="], { timeout: 5000 })).stdout;
  return output.split("\n").filter((line) => line.includes(helper) && line.includes(controlAddress(file))).map((line) => Number(line.trim().split(/\s+/)[0]));
}
try {
  await cli("tray");
  await new Promise((resolve) => setTimeout(resolve, 2500));
  const initial = await menus();
  if (initial.length !== 1) throw new Error("Menu bar did not survive the launching CLI");
  const response = (await exec(helper, ["--socket", controlAddress(file), "--check"], { timeout: 10_000 })).stdout;
  if (!response.includes("running")) throw new Error("Native menu helper cannot communicate with the bridge");
  await cli("tray");
  if (JSON.stringify(await menus()) !== JSON.stringify(initial)) throw new Error("Duplicate menu bar after a second launch");
  await cli("restart");
  if (!(await cli("status")).includes("running")) throw new Error("Restart failed");
  process.stdout.write("macOS menu bar survives CLI exit, uses native IPC, prevents duplicates and supports restart.\n");
} finally {
  await cli("stop");
  for (let attempt = 0; attempt < 15 && (await menus()).length; attempt++) await new Promise((resolve) => setTimeout(resolve, 1000));
  if ((await menus()).length) throw new Error("Menu bar did not exit after bridge stop");
  fs.rmSync(directory, { recursive: true, force: true });
}
