import { once } from "node:events";
import { gunzipSync } from "node:zlib";
import { afterEach, expect, it } from "vitest";
import WebSocket from "ws";
import { startTestBridge, type TestBridge } from "./helpers.js";

let bridge: TestBridge | undefined;
const clients: WireClient[] = [];
afterEach(async () => { clients.splice(0).forEach(c => c.ws.terminate()); await bridge?.stop(); bridge = undefined; });

class WireClient {
  readonly messages: any[] = [];
  gzipFrames = 0;
  private nextId = 0;
  private pending = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void }>();
  constructor(readonly ws: WebSocket) {
    ws.on("message", data => {
      const buffer = Buffer.from(data as Buffer);
      const zipped = buffer[0] === 0x1f && buffer[1] === 0x8b;
      if (zipped) this.gzipFrames++;
      const message = JSON.parse((zipped ? gunzipSync(buffer) : buffer).toString());
      this.messages.push(message);
      const pending = this.pending.get(message.id);
      if (pending) {
        this.pending.delete(message.id);
        if (message.error) pending.reject(new Error(message.error.message));
        else pending.resolve(message.result);
      }
    });
  }
  get bytesRead(): number { return (this.ws as any)._socket.bytesRead; }
  request(method: string, params: object): Promise<any> {
    const id = ++this.nextId;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
    });
  }
}

it("compresses long replay on the wire and preserves uncompressed client compatibility", async () => {
  bridge = await startTestBridge();
  const connect = async (compress: boolean, gzip = false) => {
    const ws = new WebSocket(bridge!.url + (gzip ? '?codeawCompression=gzip' : ''), { headers: { Authorization: `Bearer ${bridge!.tokenFor("network")}` }, perMessageDeflate: compress });
    const client = new WireClient(ws); clients.push(client);
    await once(ws, "open");
    await client.request("initialize", { protocolVersion: 1, clientCapabilities: {} });
    expect(ws.extensions.includes("permessage-deflate")).toBe(compress);
    return client;
  };
  const plain = await connect(false);
  const session = await plain.request("session/new", { cwd: bridge.home, mcpServers: [], _meta: { codeaw: { agentId: "fake" } } });
  const output = "long history 中文 output abcdef\n".repeat(12_000);
  bridge.bridge.manager.onUpdate("fake", { sessionId: session.sessionId.split(":")[1], update: {
    sessionUpdate: "tool_call", toolCallId: "wire-tool", title: "Get-Content agent.md", kind: "read", status: "completed",
    rawInput: { command: "Get-Content agent.md" }, rawOutput: { output }, content: [{ type: "content", content: { type: "text", text: output } }],
  } });
  const load = async (client: WireClient, meta: object = {}) => {
    const offset = client.messages.length, start = client.bytesRead;
    const result = await client.request("session/load", { sessionId: session.sessionId, cwd: bridge!.home, mcpServers: [], _meta: { codeaw: meta } });
    const history = client.messages.slice(offset).filter(m => ["session/update", "_codeaw/event"].includes(m.method));
    return { result, history, wireBytes: client.bytesRead - start };
  };
  await load(plain); // Drain notifications queued by the injected live update first.
  const full = await load(plain), compressed = await connect(true), zipped = await load(compressed);
  expect(full.wireBytes).toBeGreaterThan(700_000);
  expect(zipped.wireBytes).toBeLessThan(full.wireBytes / 20);
  expect(zipped.history).toEqual(full.history);
  const gzipClient = await connect(false, true), gzipReplay = await load(gzipClient);
  expect(gzipClient.gzipFrames).toBeGreaterThan(0);
  expect(gzipReplay.wireBytes).toBeLessThan(full.wireBytes / 20);
  expect(gzipReplay.history).toEqual(full.history);
  const lazy = await load(compressed, { lazyHistory: true });
  const tool = lazy.history.find(m => m.params.update?.toolCallId === "wire-tool").params.update;
  expect(tool._meta.codeaw.deferredTool).toBeDefined();
  expect(lazy.wireBytes).toBeLessThan(10_000);
  const expanded = await compressed.request("_codeaw/history/tool", { sessionId: session.sessionId, epoch: lazy.result._meta.codeaw.epoch, toolCallId: "wire-tool" });
  expect(expanded.update.rawOutput.output).toBe(output);
  expect(expanded.update.content[0].content.text).toBe(output);
  const delta = await load(compressed, { lazyHistory: true, afterSeq: lazy.result._meta.codeaw.lastSeq, epoch: lazy.result._meta.codeaw.epoch });
  expect(delta.history).toEqual([]);
  expect(delta.wireBytes).toBeLessThan(5000);
});
