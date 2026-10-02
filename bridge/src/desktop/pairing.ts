import os from "node:os";
import QRCode from "qrcode";
import { DeviceStore, formatCode } from "../server/auth.js";
import { tailscaleSelf } from "../util/tailscale.js";

/** A desktop launch stays on loopback, where browser storage works without HTTPS. */
export function createAppLaunch(home: string, port: number, listening: string[]) {
  const hosts = listening.map((address) => address.slice(0, address.lastIndexOf(":")));
  const host = hosts.find((value) => value === "127.0.0.1" || value === "localhost")
    ?? (hosts.includes("0.0.0.0") ? "127.0.0.1" : undefined)
    ?? (hosts.some((value) => value === "::1" || value === "::") ? "[::1]" : undefined);
  if (!host) throw new Error("Open App needs a local listener. Add 127.0.0.1 to listen.hosts, or use listen.hosts: auto.");
  const url = new URL(`http://${host}:${port}/`);
  url.searchParams.set("pair", "");
  url.searchParams.set("c", new DeviceStore(home).createPairingCode());
  url.searchParams.set("n", os.hostname());
  return { url: url.toString() };
}

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
