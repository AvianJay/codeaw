import type { NtfyConfig } from "../config.js";
import { logger } from "../util/log.js";

const log = logger("push");

export type PushKind = "permission" | "turn_end" | "error";

export interface PushRequest {
  kind: PushKind;
  sessionId: string;
  agentName: string;
  sessionTitle?: string;
  detail?: string;
  /** Re-checked right before sending; return false when the event no longer needs attention. */
  stillRelevant: () => boolean;
}

/**
 * Publishes to ntfy (https://ntfy.sh or a self-hosted server) when nobody is connected.
 * Delivery is delayed so a phone that is merely reconnecting does not get pinged, and
 * the text carries no conversation content unless `includeDetails` is set.
 */
export class PushNotifier {
  private readonly timers = new Set<NodeJS.Timeout>();

  constructor(
    private readonly cfg: NtfyConfig | undefined,
    private readonly hasClients: () => boolean,
    private readonly fetchImpl: typeof fetch = fetch,
  ) {}

  get enabled(): boolean {
    return !!this.cfg;
  }

  info(): { enabled: boolean; server?: string; topic?: string } {
    return this.cfg ? { enabled: true, server: this.cfg.server, topic: this.cfg.topic } : { enabled: false };
  }

  schedule(req: PushRequest): void {
    const cfg = this.cfg;
    if (!cfg) return;
    if (req.kind === "permission" && !cfg.onPermission) return;
    if (req.kind === "turn_end" && !cfg.onTurnEnd) return;
    if (req.kind === "error" && !cfg.onError) return;
    if (this.hasClients()) return;
    const timer = setTimeout(() => {
      this.timers.delete(timer);
      if (this.hasClients() || !req.stillRelevant()) return;
      void this.send(req);
    }, cfg.delaySeconds * 1000);
    timer.unref();
    this.timers.add(timer);
  }

  async send(req: Omit<PushRequest, "stillRelevant">): Promise<boolean> {
    const cfg = this.cfg;
    if (!cfg) return false;
    const what = { permission: "需要你的批准", turn_end: "已完成", error: "發生錯誤" }[req.kind];
    let message = `${req.agentName}${what}`;
    if (cfg.includeDetails) {
      if (req.sessionTitle) message += `\n${req.sessionTitle}`;
      if (req.detail) message += `\n${req.detail}`;
    }
    const body = {
      topic: cfg.topic,
      title: "codeaw",
      message,
      tags: [req.kind === "permission" ? "warning" : req.kind === "error" ? "x" : "white_check_mark"],
      priority: req.kind === "permission" ? 4 : 3,
      click: `codeaw://session/${encodeURIComponent(req.sessionId)}`,
    };
    try {
      const res = await this.fetchImpl(cfg.server.replace(/\/+$/, "") + "/", {
        method: "POST",
        headers: { "Content-Type": "application/json", ...(cfg.token ? { Authorization: `Bearer ${cfg.token}` } : {}) },
        body: JSON.stringify(body),
      });
      if (!res.ok) {
        log.warn(`ntfy responded ${res.status}`);
        return false;
      }
      return true;
    } catch (err) {
      log.warn(`ntfy publish failed: ${(err as Error).message}`);
      return false;
    }
  }

  dispose(): void {
    for (const t of this.timers) clearTimeout(t);
    this.timers.clear();
  }
}
