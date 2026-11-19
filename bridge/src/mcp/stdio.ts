import readline from "node:readline";

export const MCP_STDIO_COMMAND = "mcp-stdio";
export const MCP_URL_ENV = "CODEAW_MCP_URL";
export const MCP_TOKEN_ENV = "CODEAW_MCP_TOKEN";

/**
 * `codeaw-bridge mcp-stdio`: relays MCP JSON-RPC between an agent's stdio and the
 * bridge's loopback MCP endpoint, for agents that only launch stdio MCP servers.
 * Stdout carries protocol messages only.
 */
export async function runMcpStdio(
  input: NodeJS.ReadableStream = process.stdin,
  output: NodeJS.WritableStream = process.stdout,
  env: NodeJS.ProcessEnv = process.env,
  fetchImpl: typeof fetch = fetch,
): Promise<void> {
  const url = env[MCP_URL_ENV];
  const token = env[MCP_TOKEN_ENV];
  if (!url || !token) throw new Error(`${MCP_URL_ENV} and ${MCP_TOKEN_ENV} are set by the bridge; this command is not run by hand`);
  const pending = new Set<Promise<void>>();
  const relay = async (line: string) => {
    let id: unknown = null;
    let expectsReply = false;
    try {
      const message = JSON.parse(line);
      // Only requests are answered; a failed notification has nobody to tell.
      expectsReply = !Array.isArray(message) && message?.method !== undefined && message?.id !== undefined && message?.id !== null;
      if (expectsReply) id = message.id;
    } catch {
      output.write(JSON.stringify({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } }) + "\n");
      return;
    }
    try {
      const response = await fetchImpl(url, {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json", Authorization: `Bearer ${token}` },
        body: line,
      });
      const body = (await response.text()).trim();
      if (response.status === 202 || !body) return;
      if (!response.ok && expectsReply) throw new Error(`bridge answered HTTP ${response.status}`);
      output.write(body.replace(/\r?\n/g, " ") + "\n");
    } catch (error) {
      if (!expectsReply) return;
      output.write(JSON.stringify({ jsonrpc: "2.0", id, error: { code: -32603, message: `codeaw bridge is unreachable: ${(error as Error).message}` } }) + "\n");
    }
  };
  for await (const line of readline.createInterface({ input, crlfDelay: Infinity })) {
    if (!line.trim()) continue;
    const task = relay(line).finally(() => pending.delete(task));
    pending.add(task);
  }
  await Promise.all(pending);
}
