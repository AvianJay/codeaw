import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { Readable } from "node:stream";
import { afterEach, describe, expect, it } from "vitest";
import { listDir, PathGuard } from "../src/server/ext.js";
import { UploadStore, UploadTooLargeError, uploadName } from "../src/server/uploads.js";

const dirs: string[] = [];

function store(limit?: number): UploadStore {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-uploads-"));
  dirs.push(dir);
  return new UploadStore(dir, limit);
}

afterEach(() => {
  for (const dir of dirs.splice(0)) fs.rmSync(dir, { recursive: true, force: true });
});

describe("uploads", () => {
  it("keeps readable file names inside their own folder", () => {
    expect(uploadName("../../etc/passwd")).toBe("passwd");
    expect(uploadName("C:\\Users\\me\\報告 v2.pdf")).toBe("報告 v2.pdf");
    expect(uploadName('a<b>:"c|d?*.txt')).toBe("a_b___c_d__.txt");
    expect(uploadName("trailing. . ")).toBe("trailing");
    expect(uploadName("CON.txt")).toBe("_CON.txt");
    expect(uploadName("..")).toBe("file");
    expect(uploadName(undefined)).toBe("file");
    const long = uploadName(`${"x".repeat(300)}.tar.gz`);
    expect(long.length).toBe(120);
    expect(long.endsWith(".gz")).toBe(true);
  });

  it("saves two files with the same name separately and rejects oversized bodies", async () => {
    const uploads = store(8);
    const a = await uploads.save("notes.md", "text/markdown", Readable.from([Buffer.from("one")]));
    const b = await uploads.save("notes.md", "application/octet-stream", Readable.from([Buffer.from("two")]));
    expect(a.path).not.toBe(b.path);
    expect(a.mimeType).toBe("text/markdown");
    expect(b.mimeType).toBeUndefined();
    expect(fs.readFileSync(b.path, "utf8")).toBe("two");
    await expect(uploads.save("big.bin", undefined, Readable.from([Buffer.alloc(5), Buffer.alloc(5)]))).rejects.toBeInstanceOf(UploadTooLargeError);
    expect(fs.readdirSync(uploads.dir)).toHaveLength(2);
  });

  it("lets devices read uploads without offering them as workspaces", async () => {
    const uploads = store();
    const workspace = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-workspace-"));
    dirs.push(workspace);
    const file = await uploads.save("log.txt", undefined, Readable.from([Buffer.from("log")]));
    const guard = new PathGuard(() => [workspace], () => [], () => false, () => [uploads.dir]);
    expect(guard.resolveReadable(file.path)).toBe(fs.realpathSync.native(file.path));
    expect(() => guard.resolve(file.path)).toThrow(/outside/);
    expect(() => listDir(guard, path.dirname(file.path))).toThrow(/outside/);
    expect(guard.roots().map((r) => r.path)).toEqual([fs.realpathSync.native(workspace)]);
  });

  it("prunes uploads older than the retention period", async () => {
    const uploads = store();
    const old = await uploads.save("old.txt", undefined, Readable.from([Buffer.from("old")]));
    const fresh = await uploads.save("new.txt", undefined, Readable.from([Buffer.from("new")]));
    const past = new Date(Date.now() - 40 * 24 * 60 * 60_000);
    fs.utimesSync(path.dirname(old.path), past, past);
    uploads.prune();
    expect(fs.existsSync(old.path)).toBe(false);
    expect(fs.existsSync(fresh.path)).toBe(true);
  });
});
