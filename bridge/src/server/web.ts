import fs from "node:fs";
import path from "node:path";
import type http from "node:http";
import { fileURLToPath } from "node:url";

const MIME: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".wasm": "application/wasm",
  ".png": "image/png", ".jpg": "image/jpeg", ".svg": "image/svg+xml", ".ico": "image/x-icon",
  ".woff": "font/woff", ".woff2": "font/woff2", ".ttf": "font/ttf", ".otf": "font/otf",
};

export function findWebRoot(): string | undefined {
  const candidates = [
    // Compiled Bun releases carry a web/ folder beside the executable.
    ...(process.versions.bun ? [path.join(path.dirname(process.execPath), "web")] : []),
    fileURLToPath(new URL("../web/", import.meta.url)),
    // tsx development uses the Flutter build directly.
    fileURLToPath(new URL("../../../app/build/web/", import.meta.url)),
  ];
  return candidates.find((dir) => fs.existsSync(path.join(dir, "index.html")));
}

/** Public app assets only; /api and /acp remain under the bridge's auth handlers. */
export function serveWeb(req: http.IncomingMessage, res: http.ServerResponse, pathname: string, root?: string): boolean {
  if (!root || !["GET", "HEAD"].includes(req.method ?? "") || /^\/(api|acp)(\/|$)/.test(pathname)) return false;
  let decoded: string;
  try { decoded = decodeURIComponent(pathname); } catch { return false; }
  const parts = decoded.split("/");
  if (decoded.includes("\\") || decoded.includes("\0") || parts.some((p) => p.startsWith("."))) return false;
  const base = fs.realpathSync(root);
  let file = path.resolve(base, "." + decoded);
  const inside = (value: string) => {
    const relative = path.relative(base, value);
    return relative !== ".." && !relative.startsWith(".." + path.sep) && !path.isAbsolute(relative);
  };
  if (!inside(file)) return false;
  if (!fs.existsSync(file) || !fs.statSync(file).isFile()) {
    // History URLs get the SPA shell; missing assets must remain a 404.
    if (path.extname(decoded) || decoded.startsWith("/assets/") || decoded.startsWith("/canvaskit/")) return false;
    file = path.join(base, "index.html");
  }
  if (!inside(fs.realpathSync(file))) return false;
  const st = fs.statSync(file);
  res.writeHead(200, {
    "Content-Type": MIME[path.extname(file).toLowerCase()] ?? "application/octet-stream",
    "Content-Length": st.size,
    "Cache-Control": "no-cache",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
  });
  if (req.method === "HEAD") res.end();
  else fs.createReadStream(file).on("error", () => res.destroy()).pipe(res);
  return true;
}
