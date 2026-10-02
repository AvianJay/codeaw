import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import spawn from "cross-spawn";

const bridgeDir = fileURLToPath(new URL("../", import.meta.url));
const appDir = path.resolve(bridgeDir, "../app");
const result = spawn.sync("flutter", ["build", "web", "--release", "--no-web-resources-cdn"], {
  cwd: appDir, stdio: "inherit", windowsHide: true,
});
if (result.error) throw result.error;
if (result.status !== 0) process.exit(result.status ?? 1);
const destination = path.join(bridgeDir, "dist/web");
fs.mkdirSync(path.dirname(destination), { recursive: true });
fs.rmSync(destination, { recursive: true, force: true });
fs.cpSync(path.join(appDir, "build/web"), destination, { recursive: true });
process.stdout.write(`Bridge web app: ${destination}\n`);
