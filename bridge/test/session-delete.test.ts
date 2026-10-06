import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, expect, it } from "vitest";
import { SessionStore } from "../src/session/store.js";
import { newFakeSession, promptText, startTestBridge, TestClient, type TestBridge } from "./helpers.js";

let bridge: TestBridge | undefined;
const clients: TestClient[] = [], homes: string[] = [];
const home = () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "codeaw-delete-test-"));
  homes.push(root); return root;
};
async function connect() {
  const client = await TestClient.connect(bridge!.url, bridge!.tokenFor("delete test"));
  clients.push(client); return client;
}
afterEach(async () => {
  clients.splice(0).forEach(client => client.close());
  await bridge?.stop(); bridge = undefined;
  for (const root of homes.splice(0)) {
    if (path.dirname(path.resolve(root)) !== path.resolve(os.tmpdir()) || !path.basename(root).startsWith("codeaw-delete-test-")) throw new Error("Unsafe test cleanup");
    fs.rmSync(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
  }
});

it("removes only chat records, persists native-history filtering, and rejects deleted chat loading after restart", async () => {
  const root = home(); bridge = await startTestBridge({ home: root });
  let client = await connect();
  const removed = await newFakeSession(client, root), retained = await newFakeSession(client, root);
  await client.request("session/prompt", promptText(removed.sessionId, "echo delete fixture"));
  const nativeHistory = fs.readFileSync(path.join(root, "fake-state.json"));
  fs.writeFileSync(path.join(root, "keep.txt"), "project files remain");
  const uploads = path.join(root, ".codeaw-uploads"); fs.mkdirSync(uploads);
  fs.writeFileSync(path.join(uploads, "keep.txt"), "uploaded file remains");
  await client.request("session/delete", { sessionId: removed.sessionId });
  await client.waitFor(() => client.received.some(r => r.method === "_codeaw/activity" && r.params.sessionId === removed.sessionId && r.params.deleted));
  expect(new SessionStore(bridge.loaded.dataDir).readMeta(removed.sessionId)).toBeUndefined();
  expect((await client.request("session/list", {})).sessions.map((s: any) => s.sessionId)).not.toContain(removed.sessionId);
  await expect(client.request("session/load", { sessionId: removed.sessionId, cwd: root, mcpServers: [] })).rejects.toThrow(/deleted/);
  await client.request("session/delete", { sessionId: removed.sessionId });
  client.close(); await bridge.stop();
  // Simulate an agent retaining its native history (unsupported/failed native deletion).
  fs.writeFileSync(path.join(root, "fake-state.json"), nativeHistory);
  bridge = await startTestBridge({ home: root }); client = await connect();
  const ids = (await client.request("session/list", {})).sessions.map((s: any) => s.sessionId);
  expect(ids).not.toContain(removed.sessionId); expect(ids).toContain(retained.sessionId);
  await expect(client.request("session/resume", { sessionId: removed.sessionId, cwd: root, mcpServers: [] })).rejects.toThrow(/deleted/);
  expect(fs.readFileSync(path.join(root, "keep.txt"), "utf8")).toBe("project files remain");
  expect(fs.readFileSync(path.join(uploads, "keep.txt"), "utf8")).toBe("uploaded file remains");
});

it("refuses to delete a running turn without cancelling it", async () => {
  const root = home(); bridge = await startTestBridge({ home: root });
  const client = await connect(), session = await newFakeSession(client, root);
  const running = client.request("session/prompt", promptText(session.sessionId, "slow 30"));
  await client.waitFor(() => client.events(session.sessionId, "state").some(e => e.event.state === "running"));
  await expect(client.request("session/delete", { sessionId: session.sessionId })).rejects.toThrow(/busy/);
  expect((await running).stopReason).toBe("end_turn");
  expect(new SessionStore(bridge.loaded.dataDir).readMeta(session.sessionId)).toBeDefined();
});
