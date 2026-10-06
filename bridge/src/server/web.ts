import fs from "node:fs";
import path from "node:path";
import type http from "node:http";
import { fileURLToPath } from "node:url";
import zlib from "node:zlib";

const MIME: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".wasm": "application/wasm",
  ".png": "image/png", ".jpg": "image/jpeg", ".svg": "image/svg+xml", ".ico": "image/x-icon",
  ".woff": "font/woff", ".woff2": "font/woff2", ".ttf": "font/ttf", ".otf": "font/otf",
};

const COMPRESSIBLE = new Set([".html", ".js", ".mjs", ".json", ".css", ".wasm", ".svg", ".ttf", ".otf"]);
const MIN_GZIP_BYTES = 1024;
const MAX_GZIP_CACHE = 64;
/** Built assets rarely change, so each version is compressed once. */
const gzipped = new Map<string, Promise<Buffer>>();

function gzip(file: string, tag: string): Promise<Buffer> {
  const key = `${tag}${file}`;
  let data = gzipped.get(key);
  if (!data) {
    data = fs.promises.readFile(file).then((raw) => new Promise<Buffer>((resolve, reject) =>
      zlib.gzip(raw, { level: 9 }, (error, out) => error ? reject(error) : resolve(out))));
    data.catch(() => gzipped.delete(key));
    if (gzipped.size >= MAX_GZIP_CACHE) gzipped.delete(gzipped.keys().next().value!);
    gzipped.set(key, data);
  }
  return data;
}

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
  const ext = path.extname(file).toLowerCase();
  // Revalidated on every load, but unchanged assets cost a 304 instead of megabytes.
  const tag = `W/"${st.size.toString(16)}-${Math.floor(st.mtimeMs).toString(16)}"`;
  const compressible = COMPRESSIBLE.has(ext);
  const headers: http.OutgoingHttpHeaders = {
    "Content-Type": MIME[ext] ?? "application/octet-stream",
    "Cache-Control": "no-cache",
    ETag: tag,
    ...(compressible ? { Vary: "Accept-Encoding" } : {}),
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
  };
  if (req.headers["if-none-match"]?.split(",").some((value) => value.trim() === tag)) {
    res.writeHead(304, headers);
    res.end();
    return true;
  }
  if (compressible && st.size >= MIN_GZIP_BYTES && /\bgzip\b/.test(String(req.headers["accept-encoding"] ?? ""))) {
    gzip(file, tag).then((data) => {
      res.writeHead(200, { ...headers, "Content-Encoding": "gzip", "Content-Length": data.length });
      res.end(req.method === "HEAD" ? undefined : data);
    }, () => res.destroy());
    return true;
  }
  res.writeHead(200, { ...headers, "Content-Length": st.size });
  if (req.method === "HEAD") res.end();
  else fs.createReadStream(file).on("error", () => res.destroy()).pipe(res);
  return true;
}
