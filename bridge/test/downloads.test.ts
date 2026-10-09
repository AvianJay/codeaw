import fs from "node:fs";
import path from "node:path";
import http from "node:http";
import { createHash } from "node:crypto";
import { once } from "node:events";
import * as yauzl from "yauzl";
import { afterEach, expect, it, vi } from "vitest";
import { PathGuard } from "../src/server/ext.js";
import { prepareArchive, MAX_ARCHIVE_BYTES, attachmentHeader } from "../src/server/downloads.js";
import { startTestBridge, type TestBridge } from "./helpers.js";

let bridge: TestBridge | undefined;
afterEach(async () => { vi.restoreAllMocks(); await bridge?.stop(); bridge = undefined; });
const sha = (bytes: Buffer) => createHash("sha256").update(bytes).digest("hex");
async function unzip(bytes: Buffer): Promise<Map<string, Buffer>> {
  const zip = await new Promise<yauzl.ZipFile>((resolve, reject) => yauzl.fromBuffer(bytes, { lazyEntries: true }, (error, zip) => error ? reject(error) : resolve(zip!)));
  const files = new Map<string, Buffer>();
  return new Promise((resolve, reject) => {
    zip.on("error", reject);zip.on("end", () => resolve(files));
    zip.on("entry", (entry: yauzl.Entry) => {
      zip.openReadStream(entry, async (error, stream) => {
        if (error) return reject(error);
        try { const chunks: Buffer[] = [];for await (const chunk of stream!) chunks.push(chunk);files.set(entry.fileName, Buffer.concat(chunks));zip.readEntry(); }
        catch (error) { reject(error); }
      });
    });
    zip.readEntry();
  });
}

it("downloads exact WAV bytes with authentication, Unicode name and fresh attachment headers", async () => {
  bridge = await startTestBridge();
  const file = path.join(bridge.home, '蔥 音樂.wav'),bytes = Buffer.alloc(1024 * 1024 + 13, 0x91);
  fs.writeFileSync(file,bytes);
  const url = `${bridge.http}/api/fs/raw?download=1&path=${encodeURIComponent(file)}`;
  expect((await fetch(url)).status).toBe(401);
  const response = await fetch(url,{headers:{Authorization:`Bearer ${bridge.tokenFor("download")}`}});
  expect(response.status).toBe(200);expect(response.headers.get("content-type")).toBe("audio/wav");
  expect(response.headers.get("content-disposition")).toContain(encodeURIComponent(path.basename(file)));
  expect(response.headers.get("cache-control")).toBe("no-store");
  expect(Number(response.headers.get("content-length"))).toBe(bytes.length);
  expect(sha(Buffer.from(await response.arrayBuffer()))).toBe(sha(bytes));
  expect(attachmentHeader('bad\r\n".wav')).not.toMatch(/[\r\n]/);
});

it("streams a known-size ZIP with Unicode files, nested and empty folders and no duplicates", async () => {
  bridge = await startTestBridge();
  const folder=path.join(bridge.home,"歌曲"),wave=path.join(folder,"音訊.wav"),text=path.join(folder,"歌詞.txt");
  fs.mkdirSync(path.join(folder,"空資料夾"),{recursive:true});
  const bytes=Buffer.alloc(24*1024*1024+7,0x57);fs.writeFileSync(wave,bytes);fs.writeFileSync(text,"初音\n歌詞");
  const response=await fetch(`${bridge.http}/api/fs/archive`,{method:"POST",headers:{Authorization:`Bearer ${bridge.tokenFor("zip")}`,"Content-Type":"application/json"},body:JSON.stringify({path:bridge.home,paths:[folder,wave,wave]})});
  expect(response.status).toBe(200);expect(response.headers.get("content-type")).toBe("application/zip");
  const archive=Buffer.from(await response.arrayBuffer());expect(archive.length).toBe(Number(response.headers.get("content-length")));
  const files=await unzip(archive);expect(files.size).toBe(4);
  expect(sha(files.get("歌曲/音訊.wav")!)).toBe(sha(bytes));expect(files.get("歌曲/歌詞.txt")!.toString()).toBe("初音\n歌詞");
  expect(files.has("歌曲/空資料夾/")).toBe(true);expect(files.has("歌曲/")).toBe(true);
},15_000);

it("rejects unauthenticated, outside-directory, missing and malformed selections before emitting ZIP bytes", async () => {
  bridge=await startTestBridge();const token=bridge.tokenFor("zip-security"),file=path.join(bridge.home,"file.txt");fs.writeFileSync(file,"inside");
  const post=(body:object,auth=true)=>fetch(`${bridge!.http}/api/fs/archive`,{method:"POST",headers:{...(auth?{Authorization:`Bearer ${token}`}:{})},body:JSON.stringify(body)});
  expect((await post({path:bridge.home,paths:[file]},false)).status).toBe(401);
  for(const [body,status] of [[{path:bridge.home,paths:[path.dirname(bridge.home)]},403],[{path:bridge.home,paths:["../escape"]},400],[{path:bridge.home,paths:[]},400],[{path:bridge.home,paths:[path.join(bridge.home,"missing")]},404],[{path:bridge.home,paths:new Array(501).fill(file)},400]] as const){
    const response=await post(body);expect(response.status).toBe(status);expect(response.headers.get("content-type")).toContain("application/json");
  }
  const raw=await fetch(`${bridge.http}/api/fs/raw?download=1&path=${encodeURIComponent(path.dirname(bridge.home))}`,{headers:{Authorization:`Bearer ${token}`}});expect(raw.status).toBe(403);
});

it("does not follow junctions within selected folders or let selected symlinks escape the guard", async () => {
  bridge=await startTestBridge();const dir=path.join(bridge.home,"folder"),escape=path.join(dir,"escape");fs.mkdirSync(dir);
  fs.writeFileSync(path.join(dir,"safe.txt"),"safe");fs.symlinkSync(path.dirname(bridge.home),escape,process.platform==="win32"?"junction":"dir");
  const guard=new PathGuard(()=>[bridge!.home],()=>[]);
  expect((await prepareArchive(guard,{path:bridge.home,paths:[dir]})).entries.map(e=>e.name)).toEqual(["folder/","folder/safe.txt"]);
  await expect(prepareArchive(guard,{path:bridge.home,paths:[escape]})).rejects.toThrow(/outside/);
});

it("checks ZIP byte limits without allocating a file buffer", async () => {
  bridge=await startTestBridge();const file=path.join(bridge.home,"large.bin");fs.writeFileSync(file,"");
  const stat=fs.statSync(file);vi.spyOn(fs.promises,"stat").mockResolvedValue(Object.assign(stat,{size:MAX_ARCHIVE_BYTES+1}));
  await expect(prepareArchive(new PathGuard(()=>[bridge!.home],()=>[]),{path:bridge.home,paths:[file]})).rejects.toThrow(/2 GiB/);
});

it("closes the active source and remains responsive when a ZIP download is cancelled", async () => {
  bridge=await startTestBridge();const file=path.join(bridge.home,"cancel.bin"),fd=fs.openSync(file,"w");fs.ftruncateSync(fd,64*1024*1024);fs.closeSync(fd);
  const streams:fs.ReadStream[]=[],original=fs.createReadStream;
  vi.spyOn(fs,"createReadStream").mockImplementation(((...args:Parameters<typeof fs.createReadStream>)=>{const stream=original(...args);streams.push(stream);return stream;}) as typeof fs.createReadStream);
  const request=http.request(`${bridge.http}/api/fs/archive`,{method:"POST",headers:{Authorization:`Bearer ${bridge.tokenFor("cancel")}`}});
  request.on("error",()=>{});request.end(JSON.stringify({path:bridge.home,paths:[file]}));
  const [response]=await once(request,"response") as [http.IncomingMessage];response.on("error",()=>{});
  await once(response,"data");response.destroy();
  await vi.waitFor(()=>expect(streams.length).toBeGreaterThan(0));
  await vi.waitFor(()=>expect(streams.every(s=>s.destroyed)).toBe(true));
  expect((await fetch(`${bridge.http}/api/health`)).status).toBe(200);
});
