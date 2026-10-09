import { NativeDesktop } from "../src/remote-desktop/native.js";
const backend = new NativeDesktop("user");
try {
  const info = (await backend.request("info")).result;
  const codec = (await backend.request("selfTest")).result;
  const summary: Record<string, unknown> = { h264: codec.annexB, encodedTestBytes: codec.encodedBytes, monitors: info.monitors.length, hardware: info.hardware };
  if (!process.argv.includes("--synthetic-only") && info.monitors.length) {
    await backend.request("configure", { monitorId: info.monitors[0].id });
    const first = await backend.request("capture", { longEdge: 960, quality: 45, full: true });
    if (!first.result.tiles.length || !first.payload.length) throw new Error("Desktop capture produced no image");
    for (const tile of first.result.tiles) {
      if (tile.offset < 0 || tile.length < 1 || tile.offset + tile.length > first.payload.length || tile.x + tile.width > first.result.width || tile.y + tile.height > first.result.height) throw new Error("Invalid desktop tile");
    }
    await backend.request("ack");
    const second = await backend.request("capture", { longEdge: 960, quality: 45, full: false });
    Object.assign(summary, { width: first.result.width, height: first.result.height, firstFrameBytes: first.payload.length, changedTiles: second.result.tiles.length });
  }
  // Metadata only. Desktop pixels and typed input never enter stdout or files.
  process.stdout.write(JSON.stringify(summary) + "\n");
} finally { await backend.dispose(); }
