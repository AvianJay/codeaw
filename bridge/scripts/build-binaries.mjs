import fs from "node:fs";
import path from "node:path";
import spawn from "cross-spawn";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

const bridgeDir = fileURLToPath(new URL("../", import.meta.url));
const { values } = parseArgs({
  options: {
    target: {
      type: "string",
      default: `bun-${process.platform === "win32" ? "windows" : process.platform}-${process.arch}`,
    },
    "out-dir": { type: "string", default: "dist/bin" },
  },
});
const pkg = JSON.parse(fs.readFileSync(new URL("../package.json", import.meta.url), "utf8"));
const bins = typeof pkg.bin === "string" ? { [pkg.name.replace(/^@[^/]+\//, "")]: pkg.bin } : pkg.bin;
if (!bins || Object.keys(bins).length === 0) throw new Error("No package.json bin entries to build.");

const outputDir = path.resolve(bridgeDir, values["out-dir"]);
const windows = values.target.includes("windows");
const macos = values.target.includes("darwin");
if (windows && process.platform !== "win32") {
  throw new Error("Build Windows executables on Windows so Bun can embed the app icon.");
}
fs.mkdirSync(outputDir, { recursive: true });
if (macos) {
  if (process.platform !== "darwin") throw new Error("Build macOS releases on macOS so the native menu bar can be included.");
  const helper = spawn.sync(process.execPath, [path.join(bridgeDir, "scripts/build-macos.mjs"), "--out-dir", outputDir,
    "--arch", values.target.endsWith("arm64") ? "arm64" : "x64"], { cwd: bridgeDir, stdio: "inherit" });
  if (helper.error) throw helper.error;
  if (helper.status !== 0) process.exit(helper.status ?? 1);
}
// Keep the browser client with portable releases and installers.
const webDir = path.join(bridgeDir, "dist/web");
if (fs.existsSync(path.join(webDir, "index.html")) && path.resolve(outputDir, "web") !== webDir) {
  fs.cpSync(webDir, path.join(outputDir, "web"), { recursive: true });
}
for (const [name, entry] of Object.entries(bins)) {
  const suffix = windows ? ".exe" : "";
  const result = spawn.sync("bun", [
    "build", path.resolve(bridgeDir, entry), "--compile", "--minify", "--sourcemap",
    "--no-compile-autoload-dotenv", "--no-compile-autoload-bunfig",
    "--external", "@lydell/node-pty",
    ...(windows ? ["--windows-icon", path.join(bridgeDir, "src/assets/codeaw.ico")] : []),
    `--target=${values.target}`, "--outfile", path.join(outputDir, name + suffix),
  ], { cwd: bridgeDir, stdio: "inherit", windowsHide: true });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}
