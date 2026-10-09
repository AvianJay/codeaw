import { NativeDesktop } from "../src/remote-desktop/native.js";
const backend = new NativeDesktop("user");
try {
  const info = (await backend.request("info")).result;
  const codec = (await backend.request("selfTest")).result;
  const summary: Record<string, unknown> = { h264: codec.annexB, encodedTestBytes: codec.encodedBytes, monitors: info.monitors.length, hardware: info.hardware };
  if (process.argv.includes("--input") && (process.argv.includes("--synthetic-only") || !info.monitors.length)) throw new Error("Input smoke testing requires an interactive desktop");
  if (!process.argv.includes("--synthetic-only") && info.monitors.length) {
    await backend.request("configure", { monitorId: (info.monitors.find((monitor: any) => monitor.primary) ?? info.monitors[0]).id });
    const first = await backend.request("capture", { longEdge: 960, quality: 45, full: true });
    if (!first.result.tiles.length || !first.payload.length) throw new Error("Desktop capture produced no image");
    for (const tile of first.result.tiles) {
      if (tile.offset < 0 || tile.length < 1 || tile.offset + tile.length > first.payload.length || tile.x + tile.width > first.result.width || tile.y + tile.height > first.result.height) throw new Error("Invalid desktop tile");
    }
    await backend.request("ack");
    const second = await backend.request("capture", { longEdge: 960, quality: 45, full: false });
    Object.assign(summary, { width: first.result.width, height: first.result.height, firstFrameBytes: first.payload.length, changedTiles: second.result.tiles.length });
    if (process.argv.includes("--input")) {
      const original = { x: second.result.cursor.x as number, y: second.result.cursor.y as number };
      if (![original.x, original.y].every((value) => Number.isFinite(value) && value >= 0 && value <= 1)) throw new Error("Move the pointer onto the test monitor before testing input");
      const target = { x: original.x < .95 ? original.x + .01 : original.x - .01, y: original.y };
      const at = (cursor: any, point: typeof original) => Math.abs(cursor.x - point.x) < .002 && Math.abs(cursor.y - point.y) < .002;
      const waitForCursor = async (point: typeof original) => {
        // SendInput queues events; the input desktop can apply them after its reply is sent.
        const deadline = Date.now() + 1000;
        let observed = original;
        do {
          const frame = await backend.request("capture", { longEdge: 960, quality: 45, full: false });
          observed = frame.result.cursor;
          if (at(frame.result.cursor, point)) return true;
          await new Promise((resolve) => setTimeout(resolve, 25));
        } while (Date.now() < deadline);
        process.stdout.write(JSON.stringify({ pointerDelta: { x: observed.x - point.x, y: observed.y - point.y } }) + "\n");
        return false;
      };
      try {
        await backend.request("input", { input: { kind: "pointer", ...target } });
        if (!await waitForCursor(target)) throw new Error("Desktop pointer input did not reach Windows");
        summary.inputMoved = true;
      } finally {
        await backend.request("input", { input: { kind: "pointer", ...original } });
        await backend.request("release");
      }
      if (!await waitForCursor(original)) throw new Error("Desktop pointer was not restored");
      summary.inputRestored = true;
    }
  }
  // Metadata only. Desktop pixels and typed input never enter stdout or files.
  process.stdout.write(JSON.stringify(summary) + "\n");
} finally { await backend.dispose(); }
