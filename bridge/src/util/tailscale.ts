import os from "node:os";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

/** 100.64.0.0/10 is Tailscale's CGNAT range. */
export function isTailscaleIPv4(ip: string): boolean {
  const parts = ip.split(".").map(Number);
  return parts.length === 4 && parts[0] === 100 && parts[1] >= 64 && parts[1] <= 127;
}

export function tailscaleIPv4(): string | undefined {
  for (const addrs of Object.values(os.networkInterfaces())) {
    for (const a of addrs ?? []) {
      if (a.family === "IPv4" && !a.internal && isTailscaleIPv4(a.address)) return a.address;
    }
  }
  return undefined;
}

export interface TailscaleSelf {
  ip?: string;
  dnsName?: string;
  running: boolean;
}

/** Asks the tailscale CLI for this machine's MagicDNS name; falls back to interface scanning. */
export async function tailscaleSelf(): Promise<TailscaleSelf> {
  const ip = tailscaleIPv4();
  try {
    const { stdout } = await execFileAsync("tailscale", ["status", "--self", "--peers=false", "--json"], {
      windowsHide: true,
      timeout: 5000,
    });
    const json = JSON.parse(stdout);
    const dnsName = typeof json?.Self?.DNSName === "string" ? json.Self.DNSName.replace(/\.$/, "") : undefined;
    const ips: string[] = json?.Self?.TailscaleIPs ?? [];
    return {
      running: json?.BackendState === "Running",
      ip: ip ?? ips.find((x) => isTailscaleIPv4(x)),
      dnsName: dnsName || undefined,
    };
  } catch {
    return { running: !!ip, ip };
  }
}
