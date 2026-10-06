import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { parseArgs } from "node:util";
import { swiftMenuIcon } from "./macos-icon.mjs";

if (process.platform !== "darwin") throw new Error("Build the macOS menu bar on macOS with Xcode Command Line Tools.");
const root = fileURLToPath(new URL("../", import.meta.url));
const { values } = parseArgs({ options: { "out-dir": { type: "string", default: "dist/assets" }, arch: { type: "string", default: process.arch } } });
if (!["x64", "arm64"].includes(values.arch)) throw new Error("macOS architecture must be x64 or arm64");
const output = path.resolve(root, values["out-dir"]);
fs.mkdirSync(output, { recursive: true });
const cache = path.join(root, "dist/swift-cache");
fs.mkdirSync(cache, { recursive: true });
const icon = fs.readFileSync(path.join(root, "../app/android/app/src/main/res/drawable/ic_launcher_monochrome.xml"), "utf8");
const source = path.join(cache, `macos-menu-${values.arch}.swift`);
fs.writeFileSync(source, swiftMenuIcon(icon) + fs.readFileSync(path.join(root, "src/assets/macos-menu.swift"), "utf8"));
const result = spawnSync("swiftc", ["-O", "-target", `${values.arch === "x64" ? "x86_64" : "arm64"}-apple-macosx13.0`,
  "-module-cache-path", cache, source, "-o", path.join(output, "codeaw-menu")], { stdio: "inherit" });
if (result.error) throw result.error;
if (result.status !== 0) process.exit(result.status ?? 1);
