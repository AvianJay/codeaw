import fs from "node:fs";
import { parseArgs } from "node:util";
import { GatewayManifest } from "./gateway-config.js";
import { startDesktopGateway } from "./gateway.js";

// Keep executable startup separate so importing the gateway in a compiled test is safe.
const { values } = parseArgs({ options: { manifest: { type: "string" } } });
try {
  if (!values.manifest) throw new Error();
  const manifest = GatewayManifest.parse(JSON.parse(fs.readFileSync(values.manifest, "utf8")));
  const gateway = await startDesktopGateway(manifest);
  for (const signal of ["SIGINT", "SIGTERM"] as const) process.once(signal, () => { void gateway.close().finally(() => process.exit(0)); });
} catch { process.stderr.write("Desktop gateway startup failed\n"); process.exitCode = 1; }
