import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { z } from "zod";

export const GatewayManifest = z.object({
  name: z.string().regex(/^CodeawDesktop-[0-9a-f]{16}$/),
  configFile: z.string(), home: z.string(), ownerSid: z.string().regex(/^S-1-\d+(?:-\d+)+$/),
  backendPipe: z.string().regex(/^\\\\\.\\pipe\\codeaw-backend-[0-9a-f]{32}$/),
  port: z.number().int().min(1).max(65535), hosts: z.union([z.literal("auto"), z.array(z.string()).min(1)]),
  gateway: z.string(), helper: z.string(), webRoot: z.string(), enabled: z.boolean(),
});
export type GatewayManifest = z.infer<typeof GatewayManifest>;
export function gatewayName(file: string): string {
  return "CodeawDesktop-" + crypto.createHash("sha256").update(path.resolve(file).toLowerCase()).digest("hex").slice(0, 16);
}
export function gatewayManifestPath(file: string): string {
  return path.join(process.env.ProgramData ?? "C:\\ProgramData", "codeaw-desktop", gatewayName(file), "service.json");
}
export function gatewayRegistration(file: string): GatewayManifest | undefined {
  if (process.platform !== "win32") return undefined;
  try {
    const parsed = GatewayManifest.parse(JSON.parse(fs.readFileSync(gatewayManifestPath(file), "utf8")));
    if (path.resolve(parsed.configFile).toLowerCase() !== path.resolve(file).toLowerCase()) return undefined;
    return parsed;
  } catch { return undefined; }
}
