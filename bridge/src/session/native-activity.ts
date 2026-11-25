import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import zlib from "node:zlib";
import { execFile, spawnSync } from "node:child_process";
import type { AgentConfig } from "../config.js";

/**
 * Agents report a session's `updatedAt` from its file's write time, which also moves when the
 * session is merely loaded, resumed or given a model. These readers find the time of the last
 * real message in the agent's own transcript instead, so opening a chat does not reorder the list.
 */
export type TranscriptKind = "claude" | "codex";

const CHUNK = 64 * 1024;
const MAX_SCAN = 8 * 1024 * 1024;
const MAX_COMPRESSED = 64 * 1024 * 1024;
const INDEX_TTL_MS = 30_000;
const SAFE_ID = /^[A-Za-z0-9._-]+$/;
const CODEX_EVENTS = new Set(["task_started", "task_complete", "user_message", "agent_message", "turn_aborted", "item_completed"]);

export function transcriptKind(agentId: string, config: Pick<AgentConfig, "command">): TranscriptKind | undefined {
  const name = `${agentId} ${path.basename(config.command ?? "")}`.toLowerCase();
  if (name.includes("claude")) return "claude";
  if (name.includes("codex")) return "codex";
  return undefined;
}

/** `claude-desktop`, and `claude-desktop-3p` when the app uses a third-party API. */
const DESKTOP_ENTRYPOINT = Buffer.from('"entrypoint":"claude-desktop');

/** Whether `needle` occurs in the first MAX_SCAN bytes of `file`, read in chunks. */
function transcriptMentions(file: string, needle: Buffer): boolean {
  let fd: number;
  try {
    fd = fs.openSync(file, "r");
  } catch {
    return false;
  }
  try {
    const buffer = Buffer.alloc(CHUNK + needle.length);
    let carried = 0;
    for (let offset = 0; offset < MAX_SCAN;) {
      const read = fs.readSync(fd, buffer, carried, CHUNK, offset);
      if (read <= 0) return false;
      const filled = carried + read;
      if (buffer.subarray(0, filled).includes(needle)) return true;
      // Keep the tail so a match across two chunks is still found.
      carried = Math.min(needle.length - 1, filled);
      buffer.copy(buffer, 0, filled - carried, filled);
      offset += read;
    }
    return false;
  } catch {
    return false;
  } finally {
    fs.closeSync(fd);
  }
}

/** A Claude Code process the Claude desktop app runs for a chat. */
export interface DesktopHolder {
  pid: number;
  /** In a turn, or waiting inside one for the person to answer a question there. */
  busy: boolean;
  /** When the process started, in epoch milliseconds. */
  startedAt?: number;
  /** The system's own start time of the process, which tells it from a later one given the same id. */
  procStart?: string;
}

const REGISTRY_ENTRY = /^\d+\.json$/;
const REGISTRY_MAX_BYTES = 1024 * 1024;
const REGISTRY_MAX_AGE_MS = 24 * 60 * 60 * 1000;

/** Whether `pid` is a running Claude Code. A dead process's id can be reused by any program. */
export function isClaudeProcess(pid: number): boolean {
  try { process.kill(pid, 0); }
  catch (error) { if ((error as NodeJS.ErrnoException).code !== "EPERM") return false; }
  if (process.platform !== "win32") return true;
  const listed = spawnSync("tasklist.exe", ["/FI", `PID eq ${pid}`, "/FO", "CSV", "/NH"], { encoding: "utf8", windowsHide: true, timeout: 5000 });
  return /^"claude[^"]*\.exe"/im.test(listed.stdout ?? "");
}

/**
 * What became of a request to end a Claude Code process: `ended`; `gone` (it had exited);
 * `working` (it runs a shell command, left alone); `other` (the id now belongs to another
 * program); `unsupported` (not done on this system); `failed`.
 */
export type ProcessEnd = "ended" | "gone" | "working" | "other" | "unsupported" | "failed";

const PROCESS_END = new Set<ProcessEnd>(["ended", "gone", "working", "other", "failed"]);
/** Windows process start times are 100 ns ticks; the registry and the system round them differently. */
const PROC_START_SLACK = 100_000;

/**
 * Ends an idle Claude Code process so that it looks like a clean exit to the program that
 * started it. The Claude desktop app reads any other exit code as a crash and says so on the
 * chat; after a clean one it quietly starts a new process, from the transcript, on the next
 * message there.
 *
 * Left alone when it has a shell running: a dev server or a watcher started from that chat
 * would end with it. The caller checks for a subagent at work (desktopSubagentAtWork).
 * Windows only: elsewhere no signal is known to leave the app quiet, and the registry carries
 * nothing to tell the process from a later one with the same id.
 * A process ended this way leaves its registry entry behind; see forgetClaudeProcess.
 */
export function endClaudeProcess(holder: Pick<DesktopHolder, "pid" | "procStart">): Promise<ProcessEnd> {
  const pid = holder.pid;
  const started = holder.procStart && /^\d{1,18}$/.test(holder.procStart) ? holder.procStart : undefined;
  // Without its start time the process cannot be told from another program given the same id since.
  if (process.platform !== "win32" || !Number.isInteger(pid) || pid <= 1 || !started) return Promise.resolve("unsupported");
  // Single quotes only: the script travels as one command-line argument.
  const script = [
    "$ErrorActionPreference='Stop'",
    `$p=Get-CimInstance Win32_Process -Filter 'ProcessId=${pid}'`,
    "if(-not $p){'gone';exit}",
    "if($p.Name -notlike 'claude*'){'other';exit}",
    `if([math]::Abs($p.CreationDate.ToFileTimeUtc()-${started}) -gt ${PROC_START_SLACK}){'other';exit}`,
    `$k=@(Get-CimInstance Win32_Process -Filter 'ParentProcessId=${pid}'|Where-Object{$_.Name -match '^(bash|sh|zsh|fish|pwsh|powershell)\\.exe$'})`,
    "if($k.Count){'working';exit}",
    "$r=Invoke-CimMethod -InputObject $p -MethodName Terminate -Arguments @{Reason=[uint32]0}",
    "if($r.ReturnValue -eq 0){'ended'}else{'failed'}",
  ].join(";");
  return new Promise((resolve) => {
    execFile("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", script], { encoding: "utf8", windowsHide: true, timeout: 20_000 }, (error, stdout) => {
      const said = String(stdout ?? "").trim().split(/\s+/).pop() as ProcessEnd | undefined;
      resolve(!error && said && PROCESS_END.has(said) ? said : "failed");
    });
  });
}

/**
 * The Claude desktop app's own Claude Code process for this chat, from Claude Code's registry
 * of running sessions (`<config dir>/sessions/<pid>.json`). The app keeps one running while
 * the chat is open there, and for a while after; it writes that chat's transcript.
 */
export function claudeDesktopHolder(configDir: string, backendId: string, alive: (pid: number) => boolean = isClaudeProcess, now = Date.now()): DesktopHolder | undefined {
  const dir = path.join(configDir, "sessions");
  let names: string[];
  try { names = fs.readdirSync(dir); } catch { return undefined; }
  for (const name of names) {
    if (!REGISTRY_ENTRY.test(name)) continue;
    let entry: any;
    try {
      const file = path.join(dir, name);
      if (fs.statSync(file).size > REGISTRY_MAX_BYTES) continue;
      entry = JSON.parse(fs.readFileSync(file, "utf8"));
    } catch { continue; }
    if (entry?.sessionId !== backendId || !Number.isInteger(entry.pid) || entry.pid <= 1) continue;
    // `claude-desktop`, `claude-desktop-3p`; the app also names its own session.
    const desktop = typeof entry.entrypoint === "string" ? entry.entrypoint.startsWith("claude-desktop") : typeof entry.hostSessionId === "string";
    const seen = typeof entry.updatedAt === "number" ? entry.updatedAt : entry.startedAt;
    if (!desktop || typeof seen !== "number" || now - seen > REGISTRY_MAX_AGE_MS || !alive(entry.pid)) continue;
    return {
      pid: entry.pid,
      // "busy" in a turn, "waiting" on a permission prompt or a question inside one.
      busy: typeof entry.status === "string" && entry.status !== "idle",
      ...(typeof entry.startedAt === "number" ? { startedAt: entry.startedAt } : {}),
      ...(typeof entry.procStart === "string" ? { procStart: entry.procStart } : {}),
    };
  }
  return undefined;
}

/**
 * Removes the registry entry of a process that was ended from outside and so could not remove
 * it itself. Left in place, the entry would name whichever program is given that process id next.
 */
export function forgetClaudeProcess(configDir: string, backendId: string, holder: Pick<DesktopHolder, "pid" | "procStart">): void {
  if (!Number.isInteger(holder.pid) || holder.pid <= 1) return;
  const file = path.join(configDir, "sessions", `${holder.pid}.json`);
  try {
    if (fs.statSync(file).size > REGISTRY_MAX_BYTES) return;
    const entry = JSON.parse(fs.readFileSync(file, "utf8"));
    // A new process with the same id has written its own entry over it.
    if (entry?.pid !== holder.pid || entry.sessionId !== backendId || entry.procStart !== holder.procStart) return;
    fs.rmSync(file);
  } catch {
    // already gone, or not ours to read
  }
}

/** Claude Code names a project directory after its cwd, with every other character as a dash. */
export function claudeProjectSlug(cwd: string): string {
  return cwd.replace(/[^A-Za-z0-9]/g, "-");
}

function claudeConfigDir(config: Pick<AgentConfig, "env">): string {
  return config.env?.CLAUDE_CONFIG_DIR ?? process.env.CLAUDE_CONFIG_DIR ?? path.join(os.homedir(), ".claude");
}

/** The newest conversation line of a transcript. */
export interface TranscriptTurn {
  /** ISO time of the line. */
  at: string;
  /** Its turn had ended there: the agent's final answer, or a request the person interrupted. */
  settled: boolean;
}

/** Claude Code's stop reasons for an answer that ends the turn; "tool_use" continues it. */
const CLAUDE_FINAL_STOPS = new Set(["end_turn", "stop_sequence", "max_tokens", "refusal"]);
const CODEX_TURN_ENDS = new Set(["task_complete", "turn_aborted"]);

function claudeText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.map((part) => (part?.type === "text" && typeof part.text === "string" ? part.text : "")).join("");
}

function settledAt(kind: TranscriptKind, entry: any): boolean {
  if (kind === "codex") return entry.type === "event_msg" && CODEX_TURN_ENDS.has(entry.payload?.type);
  if (entry.type === "assistant") return CLAUDE_FINAL_STOPS.has(entry.message?.stop_reason);
  return claudeText(entry.message?.content).trimStart().startsWith("[Request interrupted by user");
}

function isActivity(kind: TranscriptKind, line: string): TranscriptTurn | undefined {
  if (!line.includes('"timestamp"')) return undefined;
  if (kind === "claude" && !line.includes('"type":"user"') && !line.includes('"type":"assistant"')) return undefined;
  if (kind === "codex" && !line.includes('"type":"response_item"') && !line.includes('"type":"event_msg"')) return undefined;
  let entry: any;
  try {
    entry = JSON.parse(line);
  } catch {
    return undefined;
  }
  if (typeof entry?.timestamp !== "string" || Number.isNaN(Date.parse(entry.timestamp))) return undefined;
  if (kind === "claude") {
    if ((entry.type !== "user" && entry.type !== "assistant") || entry.isMeta === true || entry.isSidechain === true) return undefined;
  } else if (entry.type !== "response_item" && !(entry.type === "event_msg" && CODEX_EVENTS.has(entry.payload?.type))) {
    return undefined;
  }
  return { at: new Date(entry.timestamp).toISOString(), settled: settledAt(kind, entry) };
}

/** Codex compresses older transcripts whole, so those cannot be read from the end. */
function lastCompressedActivity(file: string, kind: TranscriptKind): TranscriptTurn | undefined {
  const inflate = (zlib as { zstdDecompressSync?: (data: Buffer) => Buffer }).zstdDecompressSync;
  if (!inflate) return undefined;
  try {
    if (fs.statSync(file).size > MAX_COMPRESSED) return undefined;
    const text = inflate(fs.readFileSync(file)).toString("utf8");
    for (let end = text.length; end > 0;) {
      const start = text.lastIndexOf("\n", end - 1);
      const at = end - start > 1 ? isActivity(kind, text.slice(start + 1, end)) : undefined;
      if (at) return at;
      end = start;
    }
  } catch {
    // unreadable or damaged archive
  }
  return undefined;
}

/** Scans a JSONL transcript backwards for its newest conversation line's time. */
export function lastTranscriptActivity(file: string, kind: TranscriptKind): string | undefined {
  return lastTranscriptTurn(file, kind)?.at;
}

/** Scans a JSONL transcript backwards for its newest conversation line. */
export function lastTranscriptTurn(file: string, kind: TranscriptKind): TranscriptTurn | undefined {
  if (file.endsWith(".zst")) return lastCompressedActivity(file, kind);
  return lastLine(file, (line) => isActivity(kind, line));
}

/** The newest line of a Claude chat's own message chain. */
export interface ChainWrite {
  /** Epoch milliseconds of the line. */
  at: number;
  /** Written by the Claude desktop app's process, not by another program's. */
  desktop: boolean;
}

function chainWrite(line: string): ChainWrite | undefined {
  if (!line.includes('"uuid"') || !line.includes('"timestamp"')) return undefined;
  let entry: any;
  try {
    entry = JSON.parse(line);
  } catch {
    return undefined;
  }
  // Subagents keep their own chains; lines without an id (titles, settings) are not messages.
  if (typeof entry?.uuid !== "string" || entry.isSidechain === true || typeof entry.timestamp !== "string") return undefined;
  const at = Date.parse(entry.timestamp);
  if (Number.isNaN(at)) return undefined;
  return { at, desktop: typeof entry.entrypoint === "string" && entry.entrypoint.startsWith("claude-desktop") };
}

/**
 * Who wrote last in a Claude chat. Every process appends to the chain it holds in memory, so
 * one that started before this line and did not write it no longer has the whole conversation.
 */
export function lastChainWrite(file: string): ChainWrite | undefined {
  return lastLine(file, chainWrite);
}

/** A subagent that wrote this long ago and never finished is taken to have ended with its process. */
const SUBAGENT_QUIET_MS = 10 * 60 * 1000;
const SUBAGENT_META = /^agent-[A-Za-z0-9_-]+\.meta\.json$/;

/** Which kind of program wrote a transcript line, for lines that say. */
function writer(line: string): { desktop: boolean } | undefined {
  if (!line.includes('"entrypoint"')) return undefined;
  try {
    const entrypoint = JSON.parse(line)?.entrypoint;
    return typeof entrypoint === "string" ? { desktop: entrypoint.startsWith("claude-desktop") } : undefined;
  } catch {
    return undefined;
  }
}

/**
 * Whether a subagent of this chat is at work in the Claude desktop app's process: one that
 * runs in the background keeps going while the chat itself is idle, and ends with the process.
 * Claude Code keeps each subagent's transcript, and a note of whether it finished, in the
 * chat's own folder next to its transcript.
 */
export function desktopSubagentAtWork(transcript: string, now = Date.now()): boolean {
  const dir = path.join(transcript.replace(/\.jsonl$/, ""), "subagents");
  let names: string[];
  try { names = fs.readdirSync(dir); } catch { return false; }
  for (const name of names) {
    if (!SUBAGENT_META.test(name)) continue;
    const log = path.join(dir, name.replace(/\.meta\.json$/, ".jsonl"));
    try {
      if (now - fs.statSync(log).mtimeMs > SUBAGENT_QUIET_MS) continue;
      if (JSON.parse(fs.readFileSync(path.join(dir, name), "utf8"))?.finished === true) continue;
    } catch { continue; }
    if (lastLine(log, writer)?.desktop) return true;
  }
  return false;
}

/** The newest line of a JSONL file that `pick` accepts, reading backwards from its end. */
function lastLine<T>(file: string, pick: (line: string) => T | undefined): T | undefined {
  let fd: number;
  try {
    fd = fs.openSync(file, "r");
  } catch {
    return undefined;
  }
  try {
    let end = fs.fstatSync(fd).size;
    const stop = Math.max(0, end - MAX_SCAN);
    let tail = Buffer.alloc(0);
    while (end > stop) {
      const start = Math.max(stop, end - CHUNK);
      const chunk = Buffer.alloc(end - start);
      fs.readSync(fd, chunk, 0, chunk.length, start);
      tail = Buffer.concat([chunk, tail]);
      end = start;
      // Everything after the first newline is complete lines; the head may still be cut.
      const first = end === 0 ? -1 : tail.indexOf(0x0a);
      if (end !== 0 && first < 0) continue;
      const lines = tail.subarray(first + 1).toString("utf8").split("\n");
      for (let i = lines.length - 1; i >= 0; i--) {
        const found = lines[i] ? pick(lines[i]) : undefined;
        if (found) return found;
      }
      tail = tail.subarray(0, first + 1);
    }
    return undefined;
  } catch {
    return undefined;
  } finally {
    fs.closeSync(fd);
  }
}

export class NativeActivity {
  private readonly cache = new Map<string, { mtimeMs: number; size: number; turn: TranscriptTurn | undefined }>();
  private readonly indexes = new Map<string, { builtAt: number; files: Map<string, string> }>();
  private readonly desktop = new Map<string, { size: number; found: boolean }>();

  /** ISO time of the last real message, or undefined when this agent's transcript is unknown. */
  lastMessageAt(agentId: string, config: Pick<AgentConfig, "command" | "env">, backendId: string, cwd?: string): string | undefined {
    return this.lastTurn(agentId, config, backendId, cwd)?.at;
  }

  /** The last real message and whether its turn had ended, or undefined when unknown. */
  lastTurn(agentId: string, config: Pick<AgentConfig, "command" | "env">, backendId: string, cwd?: string): TranscriptTurn | undefined {
    const kind = transcriptKind(agentId, config);
    if (!kind || !SAFE_ID.test(backendId)) return undefined;
    const file = kind === "claude" ? this.claudeFile(config, backendId, cwd) : this.codexFile(config, backendId);
    if (!file) return undefined;
    let stat: fs.Stats;
    try {
      stat = fs.statSync(file);
    } catch {
      return undefined;
    }
    const cached = this.cache.get(file);
    if (cached && cached.mtimeMs === stat.mtimeMs && cached.size === stat.size) return cached.turn;
    const turn = lastTranscriptTurn(file, kind);
    this.cache.set(file, { mtimeMs: stat.mtimeMs, size: stat.size, turn });
    return turn;
  }

  /**
   * Whether the Claude desktop app has written to this chat's transcript. Such a transcript
   * carries the app's own instructions, which name tools (`mcp__ccd_*`) that exist only there.
   */
  fromClaudeDesktop(agentId: string, config: Pick<AgentConfig, "command" | "env">, backendId: string, cwd?: string): boolean {
    if (transcriptKind(agentId, config) !== "claude" || !SAFE_ID.test(backendId)) return false;
    const file = this.claudeFile(config, backendId, cwd);
    if (!file) return false;
    let stat: fs.Stats;
    try {
      stat = fs.statSync(file);
    } catch {
      return false;
    }
    const cached = this.desktop.get(file);
    // Lines are only appended, so a match stays one.
    if (cached && (cached.found || cached.size === stat.size)) return cached.found;
    const found = transcriptMentions(file, DESKTOP_ENTRYPOINT);
    this.desktop.set(file, { size: stat.size, found });
    return found;
  }

  /** See claudeDesktopHolder. */
  claudeDesktopHolder(agentId: string, config: Pick<AgentConfig, "command" | "env">, backendId: string, alive?: (pid: number) => boolean): DesktopHolder | undefined {
    if (transcriptKind(agentId, config) !== "claude" || !SAFE_ID.test(backendId)) return undefined;
    return claudeDesktopHolder(claudeConfigDir(config), backendId, alive);
  }

  /** See forgetClaudeProcess. */
  forgetClaudeProcess(agentId: string, config: Pick<AgentConfig, "command" | "env">, backendId: string, holder: Pick<DesktopHolder, "pid" | "procStart">): void {
    if (transcriptKind(agentId, config) !== "claude" || !SAFE_ID.test(backendId)) return;
    forgetClaudeProcess(claudeConfigDir(config), backendId, holder);
  }

  /** See desktopSubagentAtWork. */
  desktopSubagentAtWork(agentId: string, config: Pick<AgentConfig, "command" | "env">, backendId: string, cwd?: string): boolean {
    if (transcriptKind(agentId, config) !== "claude" || !SAFE_ID.test(backendId)) return false;
    const file = this.claudeFile(config, backendId, cwd);
    return !!file && desktopSubagentAtWork(file);
  }

  /** See lastChainWrite. Read anew each time: it is asked once a turn, right after the file changed. */
  lastChainWrite(agentId: string, config: Pick<AgentConfig, "command" | "env">, backendId: string, cwd?: string): ChainWrite | undefined {
    if (transcriptKind(agentId, config) !== "claude" || !SAFE_ID.test(backendId)) return undefined;
    const file = this.claudeFile(config, backendId, cwd);
    return file ? lastChainWrite(file) : undefined;
  }

  private claudeFile(config: Pick<AgentConfig, "env">, backendId: string, cwd?: string): string | undefined {
    const root = path.join(claudeConfigDir(config), "projects");
    if (cwd) {
      const direct = path.join(root, claudeProjectSlug(cwd), `${backendId}.jsonl`);
      if (fs.existsSync(direct)) return direct;
    }
    return this.index(root, 1, (name) => (name.endsWith(".jsonl") ? name.slice(0, -6) : undefined)).get(backendId);
  }

  private codexFile(config: Pick<AgentConfig, "env">, backendId: string): string | undefined {
    const home = config.env?.CODEX_HOME ?? process.env.CODEX_HOME ?? path.join(os.homedir(), ".codex");
    // rollout-<local time>-<thread id>.jsonl[.zst], below sessions/<year>/<month>/<day>/
    const id = (name: string) => /^rollout-.*-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl(?:\.zst)?$/i.exec(name)?.[1];
    return this.index(path.join(home, "sessions"), 3, id).get(backendId) ?? this.index(path.join(home, "archived_sessions"), 0, id).get(backendId);
  }

  /** Maps session ids to transcript files `depth` directories below `root`. */
  private index(root: string, depth: number, idOf: (name: string) => string | undefined): Map<string, string> {
    const known = this.indexes.get(root);
    if (known && Date.now() - known.builtAt < INDEX_TTL_MS) return known.files;
    const files = new Map<string, string>();
    const walk = (dir: string, left: number): void => {
      let entries: fs.Dirent[];
      try {
        entries = fs.readdirSync(dir, { withFileTypes: true });
      } catch {
        return;
      }
      for (const entry of entries) {
        if (entry.isDirectory()) {
          if (left > 0) walk(path.join(dir, entry.name), left - 1);
        } else if (left === 0) {
          const id = idOf(entry.name);
          if (id) files.set(id, path.join(dir, entry.name));
        }
      }
    };
    walk(root, depth);
    this.indexes.set(root, { builtAt: Date.now(), files });
    return files;
  }
}
