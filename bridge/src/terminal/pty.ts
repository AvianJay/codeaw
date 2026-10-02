import { createRequire } from "node:module";
import { StringDecoder } from "node:string_decoder";

export interface ShellProcess {
  write(data: string): void;
  resize(cols: number, rows: number): void;
  kill(): void;
}

interface BunTerminal {
  write(data: string): void;
  resize(cols: number, rows: number): void;
  close(): void;
}

interface BunRuntime {
  spawn(cmd: string[], options: {
    cwd: string;
    env: NodeJS.ProcessEnv;
    windowsHide: boolean;
    terminal: { cols: number; rows: number; data(terminal: BunTerminal, data: Uint8Array): void };
  }): { terminal: BunTerminal; exited: Promise<number>; kill(): void };
}

/** Bun releases use its built-in PTY; Node uses the prebuilt node-pty adapter. */
export function spawnShell(cwd: string, cols: number, rows: number, onData: (data: string) => void, onExit: (code: number) => void) {
  const shell = process.platform === "win32" ? "powershell.exe" : process.env.SHELL || "/bin/sh";
  const args = process.platform === "win32" ? ["-NoLogo", "-NoProfile"] : ["-i"];
  const env = { ...process.env, TERM: "xterm-256color", COLORTERM: "truecolor" };
  const bun = (globalThis as typeof globalThis & { Bun?: BunRuntime }).Bun;
  let finish!: () => void;
  const closed = new Promise<void>((resolve) => { finish = resolve; });
  let pty: ShellProcess;
  if (bun) {
    const decoder = new StringDecoder("utf8");
    const proc = bun.spawn([shell, ...args], {
      cwd, env, windowsHide: true,
      terminal: { cols, rows, data: (_, bytes) => onData(decoder.write(Buffer.from(bytes))) },
    });
    void proc.exited.then((code) => {
      const tail = decoder.end();
      if (tail) onData(tail);
      proc.terminal.close();
      onExit(code);
      finish();
    });
    pty = {
      write: (data) => { proc.terminal.write(data); },
      resize: (c, r) => proc.terminal.resize(c, r),
      kill: () => proc.kill(),
    };
  } else {
    const native = createRequire(import.meta.url)("@lydell/node-pty");
    const proc = native.spawn(shell, args, { cwd, env, cols, rows, name: "xterm-256color" });
    proc.onData(onData);
    proc.onExit((e: { exitCode: number }) => { onExit(e.exitCode); finish(); });
    pty = proc;
  }
  return { pty, shell, closed };
}
