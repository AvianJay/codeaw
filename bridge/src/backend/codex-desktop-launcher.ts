import { spawn } from "node:child_process";

/** The AppX identity of the installed Codex Desktop client. */
export const CODEX_APP_ID = "OpenAI.Codex_2p2nqsd0c76g0!App";

/** The app registers the `codex` URI scheme; this opens one conversation. */
export function codexThreadUri(conversationId: string): string {
  return `codex://threads/${conversationId}`;
}

/** The shell target that starts Codex Desktop itself (no thread selected). */
export function codexAppShellTarget(): string {
  return `shell:AppsFolder\\${CODEX_APP_ID}`;
}

/** Only safe thread identifiers are ever interpolated into a URI. */
export function isLaunchableConversation(id: string): boolean {
  return /^[A-Za-z0-9._-]{1,128}$/.test(id);
}

/**
 * Test seam: replaces the OS opener so tests can assert what a resume would
 * open without starting the real application on the machine.
 */
let osOpener: ((target: string) => Promise<boolean> | boolean) | undefined;
export function setDesktopOpenerForTest(opener?: (target: string) => Promise<boolean> | boolean): void {
  osOpener = opener;
}

export interface DesktopLauncherOptions {
  /** Ignore repeat requests for the same chat within this window (ms). */
  cooldownMs?: number;
  /** Override for tests and non-Windows hosts. */
  platform?: NodeJS.Platform;
  /** False disables automatic reopen (config `desktopSync.autoLaunch`). */
  enabled?: boolean;
  /** Injected in tests; defaults to spawning the OS opener. */
  open?: (target: string) => Promise<boolean> | boolean;
}

/**
 * Reopens a Codex Desktop conversation after a reboot, a Windows restart or
 * after the user closed the app, so its owner is available again. It only asks
 * Windows to open the existing chat (or the app); it never starts a second
 * agent runtime, and it never blocks the caller while the app boots.
 */
export class CodexDesktopLauncher {
  private readonly cooldownMs: number;
  private readonly platform: NodeJS.Platform;
  private readonly disabled: boolean;
  private readonly opener: (target: string) => Promise<boolean> | boolean;
  private attempts = new Map<string, number>();

  constructor(options: DesktopLauncherOptions = {}) {
    this.cooldownMs = options.cooldownMs ?? 60000;
    this.platform = options.platform ?? process.platform;
    this.disabled = options.enabled === false;
    this.opener = options.open ?? ((target) => (osOpener ?? ((t: string) => openWithShell(t, this.platform)))(target));
  }

  get available(): boolean {
    return this.platform === "win32" && !this.disabled;
  }

  /** True when a reopen was requested, false when skipped (unsupported or cooling down). */
  resume(conversationId: string): boolean {
    if (!this.available || !isLaunchableConversation(conversationId)) return false;
    const now = Date.now();
    const last = this.attempts.get(conversationId) ?? 0;
    if (now - last < this.cooldownMs) return false;
    this.attempts.set(conversationId, now);
    // The app may already be running but not own this thread yet; opening the
    // thread URI both starts it and selects the conversation.
    void Promise.resolve(this.opener(codexThreadUri(conversationId)))
      .then((opened) => opened ? undefined : this.opener(codexAppShellTarget()))
      .catch(() => undefined);
    return true;
  }
}

/** Start the app / open a deep link through the OS, detached from the bridge. */
function openWithShell(target: string, platform: NodeJS.Platform): Promise<boolean> {
  return new Promise((resolve) => {
    try {
      const [command, args] = platform === "win32"
        ? ["cmd.exe", ["/c", "start", "", target]]
        : platform === "darwin"
          ? ["open", [target]]
          : ["xdg-open", [target]];
      const child = spawn(command, args, { windowsHide: true, detached: true, stdio: "ignore" });
      child.on("error", () => resolve(false));
      child.on("spawn", () => { child.unref(); resolve(true); });
    } catch {
      resolve(false);
    }
  });
}
