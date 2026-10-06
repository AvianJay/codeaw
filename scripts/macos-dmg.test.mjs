import assert from "node:assert/strict";
import test from "node:test";
import { createMacosDmg } from "../bridge/scripts/create-macos-dmg.mjs";

test("retries a busy disk-image helper and preserves the source and output paths", async () => {
  const calls = [], delays = [];
  await createMacosDmg("/tmp/stage with spaces", "/tmp/output.dmg", {
    spawn: (command, args) => {
      calls.push({ command, args });
      return calls.length < 3 ? { status: 1, stderr: "hdiutil: create failed - Resource busy\n" } : { status: 0 };
    },
    wait: async (delay) => { delays.push(delay); }, report: () => {},
  });
  assert.equal(calls.length, 3);
  assert.deepEqual(delays, [2000, 4000]);
  assert.equal(calls[0].command, "hdiutil");
  assert.deepEqual(calls[0].args.slice(-3), ["-srcfolder", "/tmp/stage with spaces", "/tmp/output.dmg"]);
  assert.deepEqual(calls[1], calls[0]);
});

test("does not hide persistent resource contention or permanent failures", async () => {
  for (const [stderr, expected] of [["hdiutil: create failed - Resource busy", 3], ["hdiutil: create failed - No space left on device", 1]]) {
    let calls = 0;
    await assert.rejects(createMacosDmg("stage", "disk", {
      spawn: () => { calls++; return { status: 1, stderr }; }, wait: async () => {}, report: () => {},
    }), /hdiutil failed/);
    assert.equal(calls, expected);
  }
});

test("surfaces an unavailable hdiutil immediately", async () => {
  const error = new Error("spawn hdiutil ENOENT");
  await assert.rejects(createMacosDmg("stage", "disk", {
    spawn: () => ({ error }), wait: async () => assert.fail("Should not retry"), report: () => {},
  }), error);
});
