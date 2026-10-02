import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import spawn from "cross-spawn";

const bridgeDir = fileURLToPath(new URL("../", import.meta.url));
const { values } = parseArgs({ options: {
  arch: { type: "string", default: process.arch === "arm64" ? "arm64" : "x64" },
  "skip-build": { type: "boolean", default: false },
  "bin-dir": { type: "string", default: "dist/bin" },
  "out-dir": { type: "string", default: "dist/installer" },
  makensis: { type: "string" },
} });
if (!["x64", "arm64"].includes(values.arch)) throw new Error("Installer architecture must be x64 or arm64");
const pkg = JSON.parse(fs.readFileSync(new URL("../package.json", import.meta.url), "utf8"));
if (!/^\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.+-]+)?$/.test(pkg.version)) throw new Error("Invalid package version for NSIS");
const version = pkg.version.split(/[-+]/)[0].split(".").map(Number);
if (version.some((part) => part > 65535)) throw new Error("NSIS version components must be at most 65535");
const binDir = path.resolve(bridgeDir, values["bin-dir"]);
const executable = path.join(binDir, "codeaw-bridge.exe");
const outputDir = path.resolve(bridgeDir, values["out-dir"]);

function run(command, args) {
  const result = spawn.sync(command, args, { cwd: bridgeDir, stdio: "inherit", windowsHide: true });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${path.basename(command)} failed (${result.status})`);
}

// Resolve the compiler before doing the more expensive executable build.
const compilerCandidates = values.makensis || process.env.MAKENSIS
  ? [values.makensis ?? process.env.MAKENSIS]
  : ["makensis", ...(process.platform === "win32" ? [
    path.join(process.env["ProgramFiles(x86)"] ?? "C:\\Program Files (x86)", "NSIS", "makensis.exe"),
    path.join(process.env.ProgramFiles ?? "C:\\Program Files", "NSIS", "makensis.exe"),
  ] : [])];
const compiler = compilerCandidates.map((candidate) => /[\\/]/.test(candidate) ? path.resolve(bridgeDir, candidate) : candidate).find((candidate) => {
  const result = spawn.sync(candidate, ["-VERSION"], { encoding: "utf8", windowsHide: true });
  const match = (result.stdout ?? "").trim().match(/^v?(\d+)\.(\d+)/);
  return result.status === 0 && match && (Number(match[1]) > 3 || (Number(match[1]) === 3 && Number(match[2]) >= 9));
});
if (!compiler) throw new Error("NSIS 3.09+ is required. Install NSIS or pass --makensis <path> (or set MAKENSIS).");

if (!values["skip-build"]) run("npm", ["run", "build:bin", "--", `--target=bun-windows-${values.arch}`, `--out-dir=${binDir}`]);
if (!fs.existsSync(executable)) throw new Error(`Missing ${executable}. Build the Windows executable first or omit --skip-build.`);
// Refuse a mislabeled x64/ARM64 payload; CI builds both targets into the same file name.
const fd = fs.openSync(executable, "r");
try {
  const header = Buffer.alloc(64);
  if (fs.readSync(fd, header, 0, 64, 0) !== 64 || header.readUInt16LE(0) !== 0x5a4d) throw new Error("Payload is not a Windows executable");
  const pe = Buffer.alloc(6);
  if (fs.readSync(fd, pe, 0, 6, header.readUInt32LE(0x3c)) !== 6 || pe.readUInt32LE(0) !== 0x4550) throw new Error("Invalid PE header");
  const expected = values.arch === "arm64" ? 0xaa64 : 0x8664;
  if (pe.readUInt16LE(4) !== expected) throw new Error(`Payload architecture does not match --arch ${values.arch}`);
} finally { fs.closeSync(fd); }

fs.mkdirSync(outputDir, { recursive: true });
const output = path.join(outputDir, `codeaw-bridge-windows-${values.arch}-setup.exe`);
const define = (key, value) => `-D${key}=${value}`;
run(compiler, ["-V3", "-INPUTCHARSET", "UTF8", "-WX", define("APP_VERSION", pkg.version), define("PRODUCT_VERSION", [...version, 0].join(".")),
  define("ARCH", values.arch), define("BRIDGE_EXE", executable), define("REPO_DIR", path.resolve(bridgeDir, "..")),
  define("INSTALLER_DIR", path.join(bridgeDir, "installer")), define("OUTPUT_FILE", output),
  path.join(bridgeDir, "installer", "windows.nsi")]);
process.stdout.write(`Installer: ${output}\n`);
