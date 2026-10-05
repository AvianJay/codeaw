import crypto from "node:crypto";
import fs from "node:fs";
import * as acp from "@agentclientprotocol/sdk";
import type { PathGuard } from "../server/ext.js";
import type { ClientHandle } from "../session/manager.js";
import { spawnShell, type ShellProcess } from "./pty.js";

const MAX_HISTORY = 512 * 1024;
const IDLE_MS = 10 * 60_000;
const MAX_TERMINALS = 8;

interface TerminalEvent {
  terminalId: string;
  seq: number;
  type: "data" | "exit";
  data?: string;
  exitCode?: number;
}

interface TerminalSession {
  id: string;
  owner: string;
  cwd: string;
  shell: string;
  pty?: ShellProcess;
  closed?: Promise<void>;
  exited: boolean;
  exitCode?: number;
  seq: number;
  history: TerminalEvent[];
  historySize: number;
  clients: Map<string, ClientHandle>;
  idle?: ReturnType<typeof setTimeout>;
}

function dimension(value: unknown, fallback: number): number {
  if (value === undefined) return fallback;
  if (typeof value !== "number" || !Number.isInteger(value) || value < 2 || value > 500) {
    throw acp.RequestError.invalidParams(undefined, "Terminal dimensions must be integers between 2 and 500");
  }
  return value;
}

/** Ephemeral, device-owned shells. Output stays in memory and never enters agent logs. */
export class TerminalManager {
  private readonly sessions = new Map<string, TerminalSession>();

  constructor(private readonly guard: PathGuard) {}

  open(owner: string, client: ClientHandle, params: Record<string, unknown>) {
    const cols = dimension(params.cols, 80);
    const rows = dimension(params.rows, 24);
    let session: TerminalSession | undefined;
    if (params.terminalId !== undefined) session = this.get(owner, params.terminalId);
    else {
      const cwd = this.guard.resolve(params.cwd);
      if (!fs.statSync(cwd).isDirectory()) throw acp.RequestError.invalidParams(undefined, "cwd must be a directory");
      session = [...this.sessions.values()].find((s) => s.owner === owner && s.cwd === cwd);
      if (!session) {
        if ([...this.sessions.values()].filter((s) => s.owner === owner).length >= MAX_TERMINALS) {
          throw acp.RequestError.invalidParams(undefined, "Close an existing terminal before opening another");
        }
        session = {
          id: "term_" + crypto.randomBytes(12).toString("hex"), owner, cwd, shell: "",
          exited: false, seq: 0, history: [], historySize: 0, clients: new Map(),
        };
        const s = session;
        try {
          const process = spawnShell(cwd, cols, rows,
            (data) => { if (data) this.append(s, { type: "data", data }); },
            (exitCode) => {
              s.exited = true;
              s.exitCode = exitCode;
              this.append(s, { type: "exit", exitCode });
            });
          s.pty = process.pty;
          s.closed = process.closed;
          s.shell = process.shell;
        } catch {
          throw acp.RequestError.invalidParams(undefined, "Cannot start the terminal shell on this bridge");
        }
        this.sessions.set(s.id, s);
      }
    }
    const after = typeof params.afterSeq === "number" && Number.isSafeInteger(params.afterSeq) && params.afterSeq >= 0 ? params.afterSeq : 0;
    const full = after === 0 || after > session.seq || after < (session.history[0]?.seq ?? 1) - 1;
    if (session.idle) clearTimeout(session.idle);
    session.idle = undefined;
    session.clients.set(client.id, client);
    if (!session.exited) session.pty!.resize(cols, rows);
    return {
      terminalId: session.id, cwd: session.cwd, shell: session.shell,
      exited: session.exited, exitCode: session.exitCode, lastSeq: session.seq, full,
      events: session.history.filter((e) => full || e.seq > after),
    };
  }

  write(owner: string, params: Record<string, unknown>) {
    const s = this.get(owner, params.terminalId);
    if (s.exited) throw acp.RequestError.invalidParams(undefined, "Terminal has exited");
    if (typeof params.data !== "string" || params.data.length > 64 * 1024) {
      throw acp.RequestError.invalidParams(undefined, "data must be a string of at most 64 KiB");
    }
    // iOS soft keyboards and xterm paste emit LF; PSReadLine treats LF as Shift+Enter.
    s.pty!.write(process.platform === "win32" ? params.data.replace(/\r?\n/g, "\r") : params.data);
    return {};
  }

  resize(owner: string, params: Record<string, unknown>) {
    const s = this.get(owner, params.terminalId);
    const cols = dimension(params.cols, 80);
    const rows = dimension(params.rows, 24);
    if (!s.exited) s.pty!.resize(cols, rows);
    return {};
  }

  async close(owner: string, id: unknown) {
    await this.destroy(this.get(owner, id));
    return {};
  }

  detach(owner: string, client: ClientHandle, id: unknown) {
    const s = this.get(owner, id);
    s.clients.delete(client.id);
    this.scheduleExpiry(s);
    return {};
  }

  removeClient(client: ClientHandle) {
    for (const s of this.sessions.values()) {
      if (s.clients.delete(client.id)) this.scheduleExpiry(s);
    }
  }

  async dispose() {
    await Promise.all([...this.sessions.values()].map((s) => this.destroy(s)));
  }

  private get(owner: string, id: unknown): TerminalSession {
    const s = typeof id === "string" ? this.sessions.get(id) : undefined;
    if (!s || s.owner !== owner) throw acp.RequestError.invalidParams(undefined, "Terminal not found");
    return s;
  }

  private append(s: TerminalSession, event: Omit<TerminalEvent, "terminalId" | "seq">) {
    const entry = { ...event, terminalId: s.id, seq: ++s.seq };
    s.history.push(entry);
    s.historySize += entry.data?.length ?? 0;
    while ((s.historySize > MAX_HISTORY || s.history.length > 4096) && s.history.length > 1) {
      s.historySize -= s.history.shift()!.data?.length ?? 0;
    }
    for (const client of s.clients.values()) void client.notify("_codeaw/terminal/event", entry);
  }

  private scheduleExpiry(s: TerminalSession) {
    if (s.clients.size || s.idle) return;
    s.idle = setTimeout(() => { void this.destroy(s); }, IDLE_MS);
    s.idle.unref();
  }

  private async destroy(s: TerminalSession) {
    this.sessions.delete(s.id);
    if (s.idle) clearTimeout(s.idle);
    if (!s.exited) {
      try { s.pty?.kill(); } catch { /* Already exited. */ }
    }
    s.clients.clear();
    await s.closed;
  }
}
