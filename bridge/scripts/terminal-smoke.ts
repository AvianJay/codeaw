import assert from "node:assert/strict";
import { startTestBridge, TestClient } from "../test/helpers.js";

// Also compilable with Bun to exercise the same built-in PTY used by releases.
const tb = await startTestBridge();
let client: TestClient | undefined;
try {
  client = await TestClient.connect(tb.url, tb.tokenFor("terminal-smoke"));
  const c = client;
  const terminal = await c.request("_codeaw/terminal/open", { cwd: tb.home, cols: 100, rows: 30 });
  const id = terminal.terminalId;
  const text = () => c.received.filter((e) => e.params.terminalId === id && e.params.type === "data")
    .map((e) => e.params.data).join("");
  await c.waitFor(() => process.platform === "win32" ? text().includes("> ") : text().length > 0);
  await c.request("_codeaw/terminal/write", {
    terminalId: id,
    data: process.platform === "win32" ? "Write-Output ('standalone-' + 'terminal')\r" : "printf 'standalone-%s\\n' terminal\r",
  });
  await c.waitFor(() => text().includes("standalone-terminal"));
  await c.request("_codeaw/terminal/write", {
    terminalId: id,
    data: process.platform === "win32" ? "Write-Output ('final-' + 'output'); exit 7\r" : "printf 'final-%s\\n' output; exit 7\r",
  });
  await c.waitFor(() => c.received.some((e) => e.params.terminalId === id && e.params.type === "exit"));
  assert.equal(c.received.find((e) => e.params.terminalId === id && e.params.type === "exit")!.params.exitCode, 7);
  assert.ok(text().includes("final-output"), "The final output must arrive before the exit event");
  console.log("Terminal smoke passed (interactive shell, streamed output, exit code).");
} finally {
  client?.close();
  await tb.stop();
}
