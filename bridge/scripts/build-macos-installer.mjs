import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { parseArgs } from "node:util";

if (process.platform !== "darwin") throw new Error("Build the macOS installer on macOS.");
const root = fileURLToPath(new URL("../", import.meta.url));
const { values } = parseArgs({ options: {
  arch: { type: "string", default: process.arch }, "bin-dir": { type: "string", default: "dist/bin" },
  "out-dir": { type: "string", default: "dist/installer" },
} });
if (!["x64", "arm64"].includes(values.arch)) throw new Error("macOS architecture must be x64 or arm64");
const bin = path.resolve(root, values["bin-dir"]);
for (const file of ["codeaw-bridge", "codeaw-menu", "web/index.html"]) {
  if (!fs.existsSync(path.join(bin, file))) throw new Error(`Missing ${file}. Build the standalone bridge, menu bar and web app first.`);
}
const output = path.resolve(root, values["out-dir"]);
fs.mkdirSync(output, { recursive: true });
const stage = fs.mkdtempSync(path.join(output, "macos-install-"));
const version = process.env.CODEAW_BUILD_VERSION ?? JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8")).version;
if (!/^\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.+-]+)?$/.test(version)) throw new Error("Invalid macOS application version");
const run = (command, args) => {
  const result = spawnSync(command, args, { stdio: "inherit" });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${command} failed (${result.status})`);
};
try {
  const contents = path.join(stage, "codeaw.app/Contents");
  fs.mkdirSync(path.join(contents, "MacOS"), { recursive: true });
  const resources = path.join(contents, "Resources");
  fs.mkdirSync(resources);
  for (const file of ["codeaw-bridge", "codeaw-menu", "web"]) fs.cpSync(path.join(bin, file), path.join(resources, file), { recursive: true });
  fs.copyFileSync(path.join(root, "../LICENSE"), path.join(resources, "LICENSE"));
  fs.writeFileSync(path.join(contents, "MacOS/codeaw"), '#!/bin/sh\nset -eu\nresources=$(CDPATH= cd -- "$(dirname -- "$0")/../Resources" && pwd)\nexec "$resources/codeaw-bridge" tray "$@"\n', { mode: 0o755 });
  fs.writeFileSync(path.join(contents, "Info.plist"), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>codeaw</string>
<key>CFBundleIdentifier</key><string>tw.codeaw.bridge</string>
<key>CFBundleExecutable</key><string>codeaw</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${version.split(/[-+]/)[0]}</string>
<key>CFBundleVersion</key><string>${version.split(/[-+]/)[0]}</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
`);
  fs.symlinkSync("/Applications", path.join(stage, "Applications"));
  fs.writeFileSync(path.join(stage, "安裝說明.txt"), "將 codeaw.app 拖到 Applications，然後開啟 App；選單列會出現 codeaw。\n首次開啟未公證版本時，請到「系統設定 → 隱私權與安全性」允許開啟。\n使用選單列「安裝 ACP agent…」安裝 Claude 或 Codex；安裝完成後重新啟動 Bridge。\n設定與配對資料保留在 ~/.codeaw。\n");
  for (const file of ["codeaw-bridge", "codeaw-menu"]) run("codesign", ["--force", "--sign", "-", path.join(resources, file)]);
  run("codesign", ["--force", "--sign", "-", path.join(stage, "codeaw.app")]);
  fs.cpSync(path.join(stage, "codeaw.app"), path.join(output, "codeaw.app"), { recursive: true });
  const disk = path.join(output, `codeaw-bridge-macos-${values.arch}-setup.dmg`);
  run("hdiutil", ["create", "-ov", "-size", "512m", "-fs", "HFS+", "-format", "UDZO", "-volname", "codeaw", "-srcfolder", stage, disk]);
  process.stdout.write(`Installer: ${disk}\n`);
} finally { fs.rmSync(stage, { recursive: true, force: true }); }
