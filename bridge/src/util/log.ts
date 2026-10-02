type Level = "debug" | "info" | "warn" | "error";

const order: Record<Level, number> = { debug: 10, info: 20, warn: 30, error: 40 };
let threshold: Level = (process.env.CODEAW_LOG as Level) in order ? (process.env.CODEAW_LOG as Level) : "info";
let silent = false;

export function setLogLevel(level: Level): void {
  threshold = level;
}

/** Tests silence the logger so vitest output stays readable. */
export function setLogSilent(value: boolean): void {
  silent = value;
}

function emit(level: Level, scope: string, msg: string, extra?: unknown): void {
  if (silent || order[level] < order[threshold]) return;
  const time = new Date().toISOString().slice(11, 23);
  let line = `${time} ${level.toUpperCase().padEnd(5)} [${scope}] ${msg}`;
  if (extra !== undefined) {
    line += " " + (extra instanceof Error ? (extra.stack ?? extra.message) : safeJson(extra));
  }
  (level === "error" || level === "warn" ? process.stderr : process.stdout).write(line + "\n");
}

function safeJson(value: unknown): string {
  try {
    const s = JSON.stringify(value);
    return s.length > 2000 ? s.slice(0, 2000) + "…" : s;
  } catch {
    return String(value);
  }
}

export interface Logger {
  debug(msg: string, extra?: unknown): void;
  info(msg: string, extra?: unknown): void;
  warn(msg: string, extra?: unknown): void;
  error(msg: string, extra?: unknown): void;
}

export function logger(scope: string): Logger {
  return {
    debug: (m, e) => emit("debug", scope, m, e),
    info: (m, e) => emit("info", scope, m, e),
    warn: (m, e) => emit("warn", scope, m, e),
    error: (m, e) => emit("error", scope, m, e),
  };
}
