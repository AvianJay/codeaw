/**
 * Starts a throwaway bridge whose only agent is the scriptable fake agent (no tokens spent).
 * Prints one JSON line {"url","token","home"} on stdout once ready, then runs until killed.
 * Used by the app's end-to-end test and for UI work on an emulator:
 *
 *   npx tsx scripts/dev-bridge.ts [--port 7861] [--host 0.0.0.0] [--steering]
 */
import { parseArgs } from "node:util";
import { startTestBridge } from "../test/helpers.js";

const { values } = parseArgs({
  options: {
    port: { type: "string" },
    host: { type: "string" },
    steering: { type: "boolean" },
  },
});

const tb = await startTestBridge({
  steering: values.steering,
  port: values.port ? Number(values.port) : 0,
  hosts: values.host ? [values.host] : ["127.0.0.1"],
});
const token = tb.tokenFor("dev");
process.stdout.write(JSON.stringify({ url: tb.url, token, home: tb.home, port: tb.bridge.port() }) + "\n");

const stop = async () => {
  await tb.stop().catch(() => undefined);
  process.exit(0);
};
process.on("SIGINT", stop);
process.on("SIGTERM", stop);
process.stdin.on("end", stop);
process.stdin.resume();
