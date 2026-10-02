import os from "node:os";
import QRCode from "qrcode";
import { DeviceStore, formatCode } from "../server/auth.js";
import { tailscaleSelf } from "../util/tailscale.js";

export async function wsUrls(port: number, listening?: string[]): Promise<string[]> {
  const ts = await tailscaleSelf();
  const urls: string[] = [];
  const bound = ts.ip && (!listening || listening.some((a) => a.startsWith(ts.ip + ":") || a.startsWith("0.0.0.0:") || a.startsWith(":::")));
  if (bound) {
    urls.push(`ws://${ts.ip}:${port}/acp`);
    if (ts.dnsName) urls.push(`ws://${ts.dnsName}:${port}/acp`);
  }
  if (!urls.length) {
    const host = listening?.map((a) => a.slice(0, a.lastIndexOf(":"))).find((h) => h !== "0.0.0.0" && h !== "::") ?? "127.0.0.1";
    urls.push(`ws://${host.includes(":") ? `[${host}]` : host}:${port}/acp`);
  }
  return urls;
}

export async function createPairing(home: string, port: number, listening?: string[]) {
  const urls = await wsUrls(port, listening);
  const code = new DeviceStore(home).createPairingCode();
  const params = new URLSearchParams();
  for (const url of urls) params.append("u", url);
  params.set("c", code);
  params.set("n", os.hostname());
  const link = `codeaw://pair?${params}`;
  return { code: formatCode(code), urls, link, port, expiresAt: Date.now() + 5 * 60_000,
    qr: await QRCode.toDataURL(link, { width: 320, margin: 2, errorCorrectionLevel: "M" }) };
}
