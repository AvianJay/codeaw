import { z } from "zod";

export const ACP_REGISTRY_URL = "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json";

const launch = {
  args: z.array(z.string()).default([]),
  env: z.record(z.string(), z.string()).default({}),
};
const BinarySchema = z.object({
  ...launch,
  archive: z.url().refine((url) => new URL(url).protocol === "https:"),
  cmd: z.string().min(1),
  sha256: z.string().regex(/^[a-f0-9]{64}$/i).optional(),
});
const PackageSchema = z.object({ ...launch, package: z.string().min(1) });
const AgentSchema = z.object({
  id: z.string().regex(/^[a-z0-9][a-z0-9_-]*$/),
  name: z.string().min(1), version: z.string().min(1), description: z.string().default(""),
  distribution: z.object({
    binary: z.record(z.string(), BinarySchema).optional(),
    npx: PackageSchema.optional(), uvx: PackageSchema.optional(),
  }),
});
export type RegistryAgent = z.infer<typeof AgentSchema>;
export type Distribution =
  | { kind: "binary"; spec: z.infer<typeof BinarySchema> }
  | { kind: "npx" | "uvx"; spec: z.infer<typeof PackageSchema> };

/** Keep the IDs already used in codeaw sessions and agent icons. */
export function configAgentId(id: string): string {
  return ({ "claude-acp": "claude", "codex-acp": "codex", "antigravity-acp": "antigravity" } as Record<string, string>)[id] ?? id;
}

export function platformTarget(platform: string = process.platform, arch: string = process.arch): string {
  return `${platform === "win32" ? "windows" : platform}-${arch === "arm64" ? "aarch64" : arch === "x64" ? "x86_64" : arch}`;
}

export function distributionFor(agent: RegistryAgent, target = platformTarget()): Distribution | undefined {
  const binary = agent.distribution.binary?.[target];
  if (binary) return { kind: "binary", spec: binary };
  if (agent.distribution.npx) return { kind: "npx", spec: agent.distribution.npx };
  if (agent.distribution.uvx) return { kind: "uvx", spec: agent.distribution.uvx };
  return undefined;
}

export function parseRegistry(input: unknown): RegistryAgent[] {
  const root = z.object({ agents: z.array(z.unknown()) }).safeParse(input);
  if (!root.success) throw new Error("ACP registry returned an invalid index");
  const agents: RegistryAgent[] = [];
  const ids = new Set<string>();
  for (const entry of root.data.agents) {
    const parsed = AgentSchema.safeParse(entry);
    // New distribution formats must not prevent the rest of the catalog from loading.
    if (parsed.success && !ids.has(parsed.data.id)) { agents.push(parsed.data); ids.add(parsed.data.id); }
  }
  if (!agents.length) throw new Error("ACP registry contains no supported entries");
  return agents.sort((a, b) => a.name.localeCompare(b.name));
}

export async function fetchRegistry(): Promise<RegistryAgent[]> {
  try {
    const response = await fetch(ACP_REGISTRY_URL, { signal: AbortSignal.timeout(10_000) });
    if (!response.ok) throw new Error("Registry request failed");
    return parseRegistry(await response.json());
  } catch { throw new Error("Cannot load the ACP registry. Check your internet connection and try again."); }
}
