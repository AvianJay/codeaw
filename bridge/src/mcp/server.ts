import crypto from "node:crypto";
import http from "node:http";
import type { AddressInfo } from "node:net";
import type * as acp from "@agentclientprotocol/sdk";
import { bridgeInvocation } from "../desktop/process.js";
import { logger } from "../util/log.js";
import { VERSION } from "../version.js";
import { mcpInstructions, mcpToolNote } from "./instructions.js";
import { MCP_STDIO_COMMAND, MCP_TOKEN_ENV, MCP_URL_ENV } from "./stdio.js";
import { DESKTOP_TURN_SERVER, DESKTOP_TURN_TOOLS, desktopTurnInstructions } from "./desktop-compat.js";
import { MCP_SERVER_NAME, MCP_TOOLS, ToolError, type McpHost, type McpTool } from "./tools.js";

const log = logger("mcp");

/** Newest first; a client asking for another revision is answered with the newest. */
const PROTOCOL_VERSIONS = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];
const MAX_BODY_BYTES = 1024 * 1024;
/** MCP clients that give a server's `instructions` to their model. Everyone else gets a note in a tool description. */
const PASSES_INSTRUCTIONS = new Set(["claude-code"]);
/** Some model APIs reject longer tool descriptions. */
const MAX_DESCRIPTION_LENGTH = 1024;
const PARSE_ERROR = -32700;
const INVALID_REQUEST = -32600;
const METHOD_NOT_FOUND = -32601;
const INVALID_PARAMS = -32602;
const INTERNAL_ERROR = -32603;

interface JsonRpcMessage {
  jsonrpc?: unknown;
  id?: unknown;
  method?: unknown;
  params?: any;
}

class RpcError extends Error {
  constructor(readonly code: number, message: string) { super(message); }
}

/** A server the bridge answers on its own path: the chat's token works for each. */
interface Profile {
  name: string;
  title: string;
  tools: McpTool[];
  instructions(): string;
  /** Whether the first tool's description carries the note for clients that drop `instructions`. */
  noted: boolean;
}

interface TokenEntry {
  sessionId?: string;
  /** Who presented this token, as named in its `initialize`. */
  client?: string;
}

/**
 * Picks the transport of a bridge-provided MCP server once the agent's capabilities
 * are known: HTTP where the agent supports it, otherwise the stdio relay that every
 * ACP agent must accept. Other servers pass through unchanged.
 */
export function resolveMcpServers(servers: unknown, http: boolean): unknown {
  if (!Array.isArray(servers)) return servers;
  return servers.map((server) => {
    const stdio = server?._meta?.codeaw?.stdio;
    if (!stdio) return server;
    if (!http) return stdio;
    const { _meta, ...rest } = server;
    return rest;
  });
}

/**
 * The bridge's own MCP server: tools that let an agent present things in the app.
 * It listens on a loopback port of its own, so it is never reachable from the tailnet,
 * and every chat has its own bearer token, which is how a tool call finds its chat.
 */
export class McpServer {
  private readonly tokens = new Map<string, TokenEntry>();
  private readonly bySession = new Map<string, string>();
  /** What agents are told about codeaw. */
  readonly instructions: string;
  private server?: http.Server;
  private port = 0;

  private readonly profiles: Map<string, Profile>;

  constructor(private readonly host: McpHost, private readonly opts: { hostName: string; instructions?: string }) {
    this.instructions = mcpInstructions(opts.hostName, opts.instructions);
    this.profiles = new Map([
      [MCP_SERVER_NAME, { name: MCP_SERVER_NAME, title: "codeaw", tools: MCP_TOOLS, instructions: () => this.instructions, noted: true }],
      [DESKTOP_TURN_SERVER, { name: DESKTOP_TURN_SERVER, title: "codeaw (Claude desktop turn tools)", tools: DESKTOP_TURN_TOOLS, instructions: desktopTurnInstructions, noted: false }],
    ]);
  }

  async start(): Promise<void> {
    const server = http.createServer((req, res) => {
      this.handle(req, res).catch((error) => {
        log.error("request failed", error);
        if (!res.headersSent) this.send(res, 500, { jsonrpc: "2.0", id: null, error: { code: INTERNAL_ERROR, message: "Internal error" } });
        else res.destroy();
      });
    });
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(0, "127.0.0.1", () => {
        server.removeListener("error", reject);
        resolve();
      });
    });
    server.on("error", (error) => log.warn(`listener: ${error.message}`));
    this.server = server;
    this.port = (server.address() as AddressInfo).port;
    log.info(`tools for agents on 127.0.0.1:${this.port}`);
  }

  async stop(): Promise<void> {
    const server = this.server;
    this.server = undefined;
    this.tokens.clear();
    this.bySession.clear();
    if (!server) return;
    await new Promise<void>((resolve) => {
      server.closeAllConnections?.();
      server.close(() => resolve());
    });
  }

  get url(): string {
    return `http://127.0.0.1:${this.port}/mcp`;
  }

  get toolNames(): string[] {
    return MCP_TOOLS.map((tool) => tool.name);
  }

  /** Credentials for a chat the agent has not named yet; `bind` them once it has. */
  issue(): string {
    const token = crypto.randomBytes(32).toString("hex");
    this.tokens.set(token, {});
    return token;
  }

  bind(token: string, sessionId: string): void {
    const entry = this.tokens.get(token);
    if (!entry) return;
    const previous = this.bySession.get(sessionId);
    if (previous && previous !== token) this.tokens.delete(previous);
    entry.sessionId = sessionId;
    this.bySession.set(sessionId, token);
  }

  /** The chat's token, the same one every time it is reopened while the bridge runs. */
  tokenFor(sessionId: string): string {
    let token = this.bySession.get(sessionId);
    if (!token) this.bind(token = this.issue(), sessionId);
    return token;
  }

  /** The MCP client that connected for a chat, e.g. `claude-code`; undefined while none has. */
  clientOf(sessionId: string): string | undefined {
    const token = this.bySession.get(sessionId);
    return token ? this.tokens.get(token)?.client : undefined;
  }

  /** Forgets a token that was never bound, or a chat's token. */
  revoke(tokenOrSessionId: string): void {
    const token = this.bySession.get(tokenOrSessionId) ?? tokenOrSessionId;
    const sessionId = this.tokens.get(token)?.sessionId;
    this.tokens.delete(token);
    if (sessionId) this.bySession.delete(sessionId);
  }

  /**
   * The ACP `mcpServers` entry for a chat. It carries both transports;
   * `resolveMcpServers` keeps the one the agent supports.
   */
  entry(token: string, server: string = MCP_SERVER_NAME): acp.McpServer {
    if (!this.profiles.has(server)) throw new Error(`Unknown MCP server ${server}`);
    const self = bridgeInvocation();
    const url = server === MCP_SERVER_NAME ? this.url : `${this.url}/${server}`;
    return {
      type: "http",
      name: server,
      url,
      headers: [{ name: "Authorization", value: `Bearer ${token}` }],
      _meta: { codeaw: { stdio: {
        name: server,
        command: self.executable,
        args: [...self.args, MCP_STDIO_COMMAND],
        env: [{ name: MCP_URL_ENV, value: url }, { name: MCP_TOKEN_ENV, value: token }],
      } } },
    };
  }

  /** A tool description that also carries what `instructions` say, for clients that drop those. */
  private withNote(description: string, client: string | undefined): string {
    if (client && PASSES_INSTRUCTIONS.has(client)) return description;
    const note = mcpToolNote(this.opts.hostName, this.opts.instructions, MAX_DESCRIPTION_LENGTH - description.length - 2);
    return note ? `${description}\n\n${note}` : description;
  }

  private send(res: http.ServerResponse, status: number, body?: unknown, headers: Record<string, string> = {}): void {
    if (body === undefined) {
      res.writeHead(status, { "Content-Length": 0, "Cache-Control": "no-store", ...headers });
      res.end();
      return;
    }
    const data = JSON.stringify(body);
    res.writeHead(status, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(data), "Cache-Control": "no-store", ...headers });
    res.end(data);
  }

  private async handle(req: http.IncomingMessage, res: http.ServerResponse): Promise<void> {
    const url = new URL(req.url ?? "/", "http://localhost");
    const profile = url.pathname === "/mcp" ? this.profiles.get(MCP_SERVER_NAME) : url.pathname.startsWith("/mcp/") ? this.profiles.get(url.pathname.slice(5)) : undefined;
    if (!profile) return this.send(res, 404, { error: "Not found" });
    // Agents are not browsers. A page that reached this port through DNS rebinding is.
    if (req.headers.origin) return this.send(res, 403, { error: "Forbidden" });
    const header = req.headers.authorization;
    const entry = header?.startsWith("Bearer ") ? this.tokens.get(header.slice(7).trim()) : undefined;
    if (!entry) return this.send(res, 401, { error: "Unauthorized" }, { "WWW-Authenticate": "Bearer" });
    // Responses are plain JSON; there is no server-initiated stream to open or session to end.
    if (req.method !== "POST") return this.send(res, 405, { error: "Method not allowed" }, { Allow: "POST" });

    let payload: unknown;
    try { payload = JSON.parse(await readBody(req)); }
    catch { return this.send(res, 400, { jsonrpc: "2.0", id: null, error: { code: PARSE_ERROR, message: "Parse error" } }); }
    const batch = Array.isArray(payload);
    const messages = (batch ? payload : [payload]) as JsonRpcMessage[];
    if (messages.length === 0) return this.send(res, 400, { jsonrpc: "2.0", id: null, error: { code: INVALID_REQUEST, message: "Invalid request" } });
    const responses: unknown[] = [];
    for (const message of messages) {
      const response = await this.dispatch(message, entry, profile);
      if (response) responses.push(response);
    }
    // Notifications and responses from the client are only acknowledged.
    if (responses.length === 0) return this.send(res, 202);
    this.send(res, 200, batch ? responses : responses[0]);
  }

  private async dispatch(message: JsonRpcMessage, entry: TokenEntry, profile: Profile): Promise<unknown> {
    if (!message || typeof message !== "object" || message.jsonrpc !== "2.0") {
      return { jsonrpc: "2.0", id: null, error: { code: INVALID_REQUEST, message: "Invalid request" } };
    }
    if (typeof message.method !== "string") return undefined;
    const isRequest = typeof message.id === "string" || typeof message.id === "number";
    if (!isRequest) return undefined;
    try {
      return { jsonrpc: "2.0", id: message.id, result: await this.call(message.method, message.params ?? {}, entry, profile) };
    } catch (error) {
      if (error instanceof RpcError) return { jsonrpc: "2.0", id: message.id, error: { code: error.code, message: error.message } };
      log.error(`${message.method} failed`, error);
      return { jsonrpc: "2.0", id: message.id, error: { code: INTERNAL_ERROR, message: "Internal error" } };
    }
  }

  private async call(method: string, params: any, entry: TokenEntry, profile: Profile): Promise<unknown> {
    switch (method) {
      case "initialize": {
        const requested = params?.protocolVersion;
        const name = params?.clientInfo?.name;
        // Each server of a chat connects on its own; the main one names the client.
        if (profile.noted || !entry.client) entry.client = typeof name === "string" && name ? name.slice(0, 80) : "unknown";
        log.debug(`${entry.client} connected to ${profile.name}${entry.sessionId ? ` for ${entry.sessionId}` : ""}`);
        return {
          protocolVersion: PROTOCOL_VERSIONS.includes(requested) ? requested : PROTOCOL_VERSIONS[0],
          capabilities: { tools: { listChanged: false } },
          serverInfo: { name: profile.name, title: profile.title, version: VERSION },
          instructions: profile.instructions(),
        };
      }
      case "ping":
        return {};
      case "tools/list":
        return {
          tools: profile.tools.map((tool, index) => ({
            name: tool.name,
            title: tool.title,
            description: index === 0 && profile.noted ? this.withNote(tool.description, entry.client) : tool.description,
            inputSchema: tool.inputSchema,
            // They present something to the user and change nothing on the computer.
            annotations: { title: tool.title, readOnlyHint: true, destructiveHint: false, openWorldHint: false },
          })),
        };
      case "tools/call": {
        const tool = profile.tools.find((candidate) => candidate.name === params?.name);
        if (!tool) throw new RpcError(INVALID_PARAMS, `Unknown tool: ${String(params?.name)}`);
        const args = params.arguments ?? {};
        if (typeof args !== "object" || Array.isArray(args)) throw new RpcError(INVALID_PARAMS, "arguments must be an object");
        const failed = (text: string) => ({ content: [{ type: "text", text }], isError: true });
        // The agent connects while its session is still being created.
        if (!entry.sessionId) return failed("This chat is still starting; try again in a moment.");
        try {
          return { content: [{ type: "text", text: await tool.run(args, entry.sessionId, this.host) }] };
        } catch (error) {
          if (error instanceof ToolError) return failed(error.message);
          log.error(`tool ${tool.name} failed`, error);
          return failed("codeaw could not do that because of an internal error.");
        }
      }
      default:
        throw new RpcError(METHOD_NOT_FOUND, `Method not found: ${method}`);
    }
  }
}

function readBody(req: http.IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks: Buffer[] = [];
    req.on("data", (chunk: Buffer) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        reject(new Error("body too large"));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}
