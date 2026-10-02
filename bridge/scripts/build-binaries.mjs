import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
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
fs.mkdirSync(outputDir, { recursive: true });
for (const [name, entry] of Object.entries(bins)) {
  const suffix = values.target.includes("windows") ? ".exe" : "";
  const result = spawnSync("bun", [
    "build", path.resolve(bridgeDir, entry), "--compile", "--minify", "--sourcemap",
    "--no-compile-autoload-dotenv", "--no-compile-autoload-bunfig",
    "--external", "@lydell/node-pty",
    `--target=${values.target}`, "--outfile", path.join(outputDir, name + suffix),
  ], { cwd: bridgeDir, stdio: "inherit" });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}
