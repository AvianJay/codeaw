import { createHash } from "node:crypto";

type Json = Record<string, any>;
const object = (value: unknown): Json => value !== null && typeof value === "object" && !Array.isArray(value) ? value as Json : {};
const string = (value: unknown): string | undefined => typeof value === "string" && value.trim() ? value.trim().slice(0, 300) : undefined;
const number = (value: unknown): number | null => {
  if (value === null || value === undefined || value === "" || typeof value === "boolean") return null;
  const result = Number(value);
  return Number.isFinite(result) ? result : null;
};
const percent = (value: unknown): number | null => { const n = number(value); return n === null ? null : Math.min(100, Math.max(0, n)); };
function instant(value: unknown): string | null {
  if (value === undefined || value === null || value === "") return null;
  const numeric = number(value);
  const ms = numeric !== null ? numeric * (numeric < 1e12 ? 1000 : 1) : Date.parse(String(value));
  return Number.isFinite(ms) && ms > 0 && ms < 8.64e15 ? new Date(ms).toISOString() : null;
}

export interface CpaWindow {
  id: string; label: string; remainingPercent: number | null; resetAt: string | null; periodSeconds: number | null;
}
export interface CpaAccount {
  id: string; name: string; provider: string; label: string; plan: string | null;
  disabled: boolean; unavailable: boolean; status: string; requests: number | null;
  subscriptionUntil: string | null;
}
export interface CpaQuota {
  accountId: string; windows: CpaWindow[]; resetsRemaining: number | null;
  plan: string | null; subscriptionUntil: string | null; checkedAt: string;
  status: "ok" | "stale" | "unsupported" | "disabled" | "error"; message?: string; retryAt?: string;
}
interface Credential { account: CpaAccount; authIndex?: string; accountId?: string; projectId?: string; userId?: string }
interface Connection { base: URL; key: string; scope: string }
interface QuotaCache { value?: CpaQuota; at: number; failures: number; profileAt?: number; pending?: Promise<CpaQuota> }
interface ScopeCache {
  at: number; usedAt: number; credentials: Credential[]; pending?: Promise<void>;
  quotas: Map<string, QuotaCache>; cooldowns: Map<string, number>; claudeStart: number;
  managementRetryAt: number; managementFailures: number;
}
class RateLimited extends Error {
  constructor(readonly retryAt?: number) { super("配額查詢暫停（HTTP 429）：服務商限制查詢頻率"); }
}
function retryAfter(headers: unknown, now: number): number | undefined {
  const entry = Object.entries(object(headers)).find(([key]) => key.toLowerCase() === "retry-after")?.[1];
  const raw = Array.isArray(entry) ? entry[0] : entry;
  if (typeof raw !== "string" && typeof raw !== "number") return undefined;
  const seconds = number(raw);
  const at = seconds !== null && seconds >= 0 ? now + seconds * 1000 : Date.parse(String(raw));
  return Number.isFinite(at) && at >= now ? at : undefined;
}

/** Accept the server root, a reverse-proxy prefix, or an explicit v0/v8 management URL. */
export function cpaConnection(params: Json): Connection {
  let base: URL;
  try { base = new URL(String(params.endpoint ?? "").trim()); } catch { throw new Error("請輸入有效的 CPA 網址"); }
  if (!["https:", "http:"].includes(base.protocol) || base.username || base.password || base.search || base.hash) {
    throw new Error("CPA 網址須為 HTTP(S)，且不可含密碼、查詢參數或片段");
  }
  let pathname = base.pathname.replace(/\/+$/, "");
  pathname = pathname.replace(/\/(management\.html|v1)$/i, "");
  if (!/\/v[08]\/management$/.test(pathname)) pathname += "/v0/management";
  base.pathname = pathname;
  const key = typeof params.managementKey === "string" ? params.managementKey.trim() : "";
  if (!key || key.length > 4096 || /[\r\n]/.test(key)) throw new Error("請輸入 CPA Management Key（不是模型 API key）");
  return { base, key, scope: createHash("sha256").update(base.href).update("\0").update(key).digest("hex") };
}

function tokenInfo(value: unknown): Json {
  if (typeof value !== "string") return object(value);
  try { return object(JSON.parse(Buffer.from(value.split(".")[1] ?? "", "base64url").toString("utf8"))); } catch { return {}; }
}
function credential(file: Json): Credential {
  const metadata = object(file.metadata), attributes = object(file.attributes);
  const token = tokenInfo(file.id_token ?? metadata.id_token ?? attributes.id_token);
  const auth = object(token["https://api.openai.com/auth"] ?? token);
  const records = [file, metadata, attributes, auth];
  const field = (...keys: string[]) => records.flatMap(r => keys.map(k => r[k])).find(v => v !== undefined && v !== null && v !== "");
  let provider = (string(field("type", "provider")) ?? "unknown").toLowerCase();
  if (["xai", "grok", "grok-build"].includes(provider)) provider = "grok";
  if (provider === "gemini-cli") provider = "gemini";
  const name = string(file.name) ?? "未命名帳號";
  const authIndexValue = field("auth_index", "authIndex");
  const authIndex = authIndexValue !== undefined ? String(authIndexValue) : undefined;
  const subscription = object(field("subscription"));
  return {
    account: {
      id: createHash("sha256").update(`${authIndex ?? ""}\0${name}\0${provider}`).digest("hex").slice(0, 24),
      name, provider,
      // CPA's `account` can be an API key. Never return or display it.
      label: string(field("email")) ?? string(token.email) ?? name,
      plan: string(field("plan_type", "planType", "subscription_plan")) ?? null,
      disabled: file.disabled === true, unavailable: file.unavailable === true,
      status: string(file.status) ?? "unknown",
      requests: number(file.success) !== null && number(file.failed) !== null ? number(file.success)! + number(file.failed)! : null,
      subscriptionUntil: instant(field("subscription_active_until", "chatgpt_subscription_active_until", "subscriptionActiveUntil") ?? subscription.active_until),
    }, authIndex,
    accountId: string(field("chatgpt_account_id", "chatgptAccountId")),
    projectId: string(field("project_id", "projectId", "gemini_virtual_project")),
    userId: string(field("sub", "subject", "user_id", "userId")),
  };
}

function remaining(used: unknown): number | null { const n = percent(used); return n === null ? null : 100 - n; }
function windowOf(id: string, label: string, raw: Json, periodSeconds: number | null, now: number): CpaWindow {
  const delay = number(raw.reset_after_seconds ?? raw.resetAfterSeconds);
  return { id, label, remainingPercent: remaining(raw.used_percent ?? raw.usedPercent ?? raw.utilization),
    resetAt: instant(raw.reset_at ?? raw.resetAt ?? raw.resets_at) ?? (delay !== null ? instant(now + Math.max(0, delay) * 1000) : null), periodSeconds };
}
export function codexWindows(payload: Json, now = Date.now()): CpaWindow[] {
  const windows: CpaWindow[] = [];
  for (const [prefix, limits] of [["", payload.rate_limit ?? payload.rateLimit], ["review-", payload.code_review_rate_limit ?? payload.codeReviewRateLimit]] as const) {
    const data = object(limits);
    const candidates = [data.primary_window ?? data.primaryWindow, data.secondary_window ?? data.secondaryWindow];
    candidates.forEach((raw, index) => {
      if (!raw || typeof raw !== "object") return;
      const period = number(raw.limit_window_seconds ?? raw.limitWindowSeconds);
      const kind = period === 18000 ? "five-hour" : period === 604800 ? "weekly" : period !== null && period >= 2419200 && period <= 2678400 ? "monthly" : period === null ? (index === 0 ? "five-hour" : "weekly") : "other";
      const label = ({ "five-hour": "5 小時", weekly: "每週", monthly: "每月", other: period === null ? "額度" : `${period / 3600} 小時` })[kind];
      const window = windowOf(prefix + kind, (prefix ? "程式審查 · " : "") + label, raw, period, now);
      // A global limit flag must not turn both windows into 0% when one is unknown.
      windows.push(window);
    });
  }
  return windows;
}
export function claudeWindows(payload: Json): CpaWindow[] {
  const labels: Record<string, string> = { five_hour: "5 小時", seven_day: "每週", seven_day_opus: "Opus · 每週", seven_day_sonnet: "Sonnet · 每週", seven_day_oauth_apps: "OAuth · 每週", seven_day_cowork: "Cowork · 每週" };
  return Object.entries(labels).flatMap(([key, label]) => {
    const raw = object(payload[key]);
    return Object.keys(raw).length ? [windowOf(key === "five_hour" ? "five-hour" : key === "seven_day" ? "weekly" : key, label, raw, key === "five_hour" ? 18000 : 604800, Date.now())] : [];
  });
}
export function resetCount(payload: Json, now = Date.now()): number | null {
  const explicit = number(payload.available_count ?? payload.availableCount);
  if (explicit !== null && explicit >= 0) return Math.floor(explicit);
  if (!Array.isArray(payload.credits)) return null;
  return payload.credits.filter((credit: Json) => credit.reset_type === "codex_rate_limits" && credit.status === "available" &&
    instant(credit.expires_at) !== null && Date.parse(instant(credit.expires_at)!) > now).length;
}
export function grokWindows(payload: Json): CpaWindow[] {
  const config = object(payload.config ?? payload);
  const period = object(config.currentPeriod ?? config.current_period);
  const end = instant(period.end ?? config.billingPeriodEnd ?? config.billing_period_end);
  const start = instant(period.start ?? config.billingPeriodStart ?? config.billing_period_start);
  const duration = end && start ? (Date.parse(end) - Date.parse(start)) / 1000 : null;
  const credits = number(config.creditUsagePercent ?? config.credit_usage_percent);
  const limit = number(config.monthlyLimit ?? config.monthly_limit), used = number(config.used);
  const usedPercent = credits ?? (limit !== null && limit > 0 && used !== null ? used / limit * 100 : null);
  if (usedPercent === null && !end) return [];
  const weekly = String(period.type ?? "").toLowerCase().includes("week") || duration === 604800 || credits !== null;
  return [{ id: weekly ? "weekly" : "monthly", label: weekly ? "每週 credits" : "每月額度", remainingPercent: remaining(usedPercent), resetAt: end, periodSeconds: duration }];
}

/** Read-only CPA adapter. No credential downloads, token exposure, reset redemption, or model calls. */
export class CpaUsageService {
  private readonly scopes = new Map<string, ScopeCache>();
  constructor(private readonly fetchImpl: typeof fetch = fetch, private readonly now = Date.now) {}

  private scope(connection: Connection): ScopeCache {
    const now = this.now();
    for (const [key, scope] of this.scopes) if (now - scope.usedAt > 1_800_000 && !scope.pending) this.scopes.delete(key);
    let scope = this.scopes.get(connection.scope);
    if (!scope) {
      if (this.scopes.size >= 12) this.scopes.delete(this.scopes.keys().next().value!);
      scope = { at: -Infinity, usedAt: now, credentials: [], quotas: new Map(), cooldowns: new Map(), claudeStart: 0,
        managementRetryAt: 0, managementFailures: 0 };
      this.scopes.set(connection.scope, scope);
    }
    scope.usedAt = now;
    return scope;
  }

  private async json(connection: Connection, path: string, body?: Json): Promise<Json> {
    const scope = this.scope(connection);
    if (scope.managementRetryAt > this.now()) throw new RateLimited(scope.managementRetryAt);
    let response: Response;
    try {
      response = await this.fetchImpl(`${connection.base.href}${path}`, {
        method: body ? "POST" : "GET", headers: { Authorization: `Bearer ${connection.key}`, "Content-Type": "application/json" },
        ...(body ? { body: JSON.stringify(body) } : {}), signal: AbortSignal.timeout(12_000), redirect: "error",
      });
    } catch { throw new Error("CPA 連線失敗或逾時，請檢查網址與電腦網路"); }
    if (!response.ok) {
      if (response.status === 429) {
        if (scope.managementRetryAt <= this.now()) scope.managementFailures++;
        const delay = Math.min(900_000, 60_000 * 2 ** Math.min(scope.managementFailures - 1, 4));
        scope.managementRetryAt = Math.max(scope.managementRetryAt, this.now() + 30_000,
          retryAfter({ "retry-after": response.headers.get("retry-after") }, this.now()) ?? this.now() + delay);
        throw new RateLimited(scope.managementRetryAt);
      }
      throw new Error(response.status === 401 || response.status === 403 ? `CPA 認證失敗（HTTP ${response.status}）：請檢查 Management Key 與遠端管理權限` : `CPA 查詢失敗（HTTP ${response.status}）`);
    }
    // Bound upstream data even when Content-Length is absent; never include its raw body in errors.
    const reader = response.body?.getReader();
    if (!reader) throw new Error("CPA 沒有回傳資料");
    const chunks: Uint8Array[] = []; let size = 0;
    for (;;) {
      const { done, value } = await reader.read(); if (done) break;
      size += value.length;
      if (size > 8 * 1024 * 1024) { await reader.cancel(); throw new Error("CPA 回應超過 8 MiB"); }
      chunks.push(value);
    }
    try { return object(JSON.parse(Buffer.concat(chunks).toString("utf8"))); } catch { throw new Error("CPA 回應不是 JSON，請確認網址指向管理 API"); }
  }

  async accounts(params: Json) {
    const connection = cpaConnection(params);
    const scope = this.scope(connection);
    if (this.now() - scope.at >= 30_000) {
      scope.pending ??= (async () => {
        const v8 = connection.base.pathname.endsWith("/v8/management");
        const payload = await this.json(connection, v8 ? "/credentials" : "/auth-files");
        if (!Array.isArray(payload.files)) throw new Error("CPA 未回傳帳號清單；請使用 CLIProxyAPI 管理端點");
        // Keep minimal query metadata and normalized quotas, never raw auth files or keys.
        scope.credentials = payload.files.map((file: unknown) => credential(object(file)));
        scope.at = this.now();
        scope.managementFailures = 0;
        const ids = new Set(scope.credentials.map(c => c.account.id));
        for (const id of scope.quotas.keys()) if (!ids.has(id)) scope.quotas.delete(id);
      })().finally(() => { scope.pending = undefined; });
      try { await scope.pending; }
      catch (error) { if (!(error instanceof RateLimited) || !Number.isFinite(scope.at)) throw error; }
    }
    return { accounts: scope.credentials.map(c => c.account), checkedAt: new Date(scope.at).toISOString() };
  }

  private async upstream(connection: Connection, c: Credential, url: string, extra: Json = {}, method = "GET", data?: Json): Promise<Json> {
    const path = connection.base.pathname.endsWith("/v8/management") ? "/requests/api-call" : "/api-call";
    const response = await this.json(connection, path, {
      authIndex: c.authIndex, method, url,
      header: { Authorization: "Bearer $TOKEN$", "Content-Type": "application/json", ...extra },
      ...(data ? { data: JSON.stringify(data) } : {}),
    });
    const status = number(response.status_code ?? response.statusCode);
    if (status === 429) throw new RateLimited(retryAfter(response.header ?? response.headers, this.now()));
    if (status === null || status < 200 || status >= 300) throw new Error(`服務商配額查詢失敗${status !== null ? `（HTTP ${status}）` : ""}`);
    if (typeof response.body === "string") {
      try { return object(JSON.parse(response.body)); } catch { throw new Error("服務商未回傳有效配額資料"); }
    }
    return object(response.body);
  }

  async quota(params: Json): Promise<CpaQuota> {
    const connection = cpaConnection(params);
    const scope = this.scope(connection);
    if (this.now() - scope.at >= 300_000) await this.accounts(params);
    const c = scope.credentials.find(c => c.account.id === params.accountId);
    if (!c) throw new Error("找不到 CPA 帳號，請重新整理清單");
    let cached = scope.quotas.get(c.account.id);
    if (!cached) { cached = { at: -Infinity, failures: 0 }; scope.quotas.set(c.account.id, cached); }
    if (cached.pending) return cached.pending;
    const cache = cached;
    const empty = (): CpaQuota => ({ accountId: c.account.id, windows: [], resetsRemaining: null, plan: c.account.plan,
      subscriptionUntil: c.account.subscriptionUntil, checkedAt: new Date(this.now()).toISOString(), status: "error" });
    if (c.account.disabled) return { ...empty(), status: "disabled", message: "帳號已停用" };
    const limited = (retryAt: number): CpaQuota => ({
      ...(cache.value?.status === "ok" || cache.value?.status === "stale" ? cache.value : empty()),
      status: cache.value?.status === "ok" || cache.value?.status === "stale" ? "stale" : "error",
      message: "查詢暫停（HTTP 429）；冷卻後自動重試", retryAt: new Date(retryAt).toISOString(),
    });
    const cooldown = Math.max(scope.cooldowns.get(c.account.provider) ?? 0, scope.managementRetryAt);
    if (cooldown > this.now()) return limited(cooldown);
    const ttl = cache.value?.status === "ok" && c.account.provider === "claude" ? 300_000 : 30_000;
    if (cache.value && this.now() - cache.at < ttl && cache.value.status !== "stale") return cache.value;
    cache.pending = (async () => {
      try {
        if (c.account.provider === "claude") {
          // Pace distinct accounts as well as coalescing the same account/device.
          const start = Math.max(this.now(), scope.claudeStart);
          scope.claudeStart = start + 1000;
          if (start > this.now()) await new Promise(resolve => setTimeout(resolve, start - this.now()));
          const retryAt = Math.max(scope.cooldowns.get("claude") ?? 0, scope.managementRetryAt);
          if (retryAt > this.now()) return limited(retryAt);
        }
        const value = await this.queryQuota(connection, c, cache);
        cache.value = value; cache.at = this.now(); cache.failures = 0;
        return value;
      } catch (error) {
        if (error instanceof RateLimited) {
          cache.failures++;
          const delay = Math.min(900_000, 60_000 * 2 ** Math.min(cache.failures - 1, 4));
          const retryAt = Math.max(this.now() + 30_000, error.retryAt ?? this.now() + delay);
          scope.cooldowns.set(c.account.provider, retryAt);
          return limited(retryAt);
        }
        const value = { ...empty(), message: error instanceof Error ? error.message : "配額查詢失敗" };
        cache.value = value; cache.at = this.now();
        return value;
      }
    })().finally(() => { cache.pending = undefined; });
    return cache.pending;
  }

  private async queryQuota(connection: Connection, c: Credential, cache: QuotaCache): Promise<CpaQuota> {
    const result: CpaQuota = { accountId: c.account.id, windows: [], resetsRemaining: null, plan: c.account.plan,
      subscriptionUntil: c.account.subscriptionUntil, checkedAt: new Date(this.now()).toISOString(), status: "ok" };
    if (c.account.disabled) return { ...result, status: "disabled", message: "帳號已停用" };
    if (!c.authIndex) return { ...result, status: "unsupported", message: "此 CPA 帳號未提供 auth_index，無法查詢配額" };
    if (c.account.provider === "codex") {
      const headers = { "User-Agent": "codex-tui/0.160.0", ...(c.accountId ? { "Chatgpt-Account-Id": c.accountId } : {}) };
      const [usage, credits, subscription] = await Promise.all([
        this.upstream(connection, c, "https://chatgpt.com/backend-api/wham/usage", headers),
        this.upstream(connection, c, "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits", { ...headers, Accept: "application/json", "OpenAI-Beta": "codex-1", Originator: "Codex Desktop" }).catch(() => null),
        c.accountId ? this.upstream(connection, c, `https://chatgpt.com/backend-api/subscriptions?account_id=${encodeURIComponent(c.accountId)}`, headers).catch(() => null) : null,
      ]);
      result.windows = codexWindows(usage);
      result.resetsRemaining = (credits ? resetCount(credits) : null) ?? resetCount(object(usage.rate_limit_reset_credits ?? usage.rateLimitResetCredits));
      result.plan = string(usage.plan_type ?? usage.planType) ?? result.plan;
      result.subscriptionUntil = instant(subscription?.active_until) ?? result.subscriptionUntil;
    } else if (c.account.provider === "claude") {
      const headers = { "anthropic-beta": "oauth-2025-04-20", "User-Agent": "claude-cli/2.1.280 (external, cli)" };
      const usage = await this.upstream(connection, c, "https://api.anthropic.com/api/oauth/usage", headers);
      // Plan is optional and changes slowly; do not query it on every poll or after a usage 429.
      let profile: Json | null = null;
      result.plan = cache.value?.plan ?? result.plan;
      if (cache.profileAt === undefined || this.now() - cache.profileAt >= 3_600_000) {
        cache.profileAt = this.now();
        profile = await this.upstream(connection, c, "https://api.anthropic.com/api/oauth/profile", headers).catch(() => null);
      }
      result.windows = claudeWindows(usage);
      if (profile?.account?.has_claude_max === true) result.plan = "Max";
      else if (profile?.account?.has_claude_pro === true) result.plan = "Pro";
      else if (profile?.organization?.organization_type === "claude_team") result.plan = "Team";
    } else if (c.account.provider === "grok") {
      const headers = { "x-xai-token-auth": "xai-grok-cli", "x-grok-client-version": "0.2.91", "User-Agent": "grok-pager/0.2.91 grok-shell/0.2.91 (macos; aarch64)", ...(c.userId ? { "x-userid": c.userId } : {}) };
      const responses = await Promise.allSettled([
        this.upstream(connection, c, "https://cli-chat-proxy.grok.com/v1/billing?format=credits", headers),
        this.upstream(connection, c, "https://cli-chat-proxy.grok.com/v1/billing", headers),
      ]);
      result.windows = responses.flatMap(r => r.status === "fulfilled" ? grokWindows(r.value) : []);
      result.windows = result.windows.filter((w, i, all) => all.findIndex(x => x.id === w.id) === i);
      if (!result.windows.length) throw new Error("Grok 未提供可讀取的配額；API key 帳號可能不支援訂閱額度");
    } else if (c.account.provider === "antigravity" && c.projectId) {
      const usage = await this.upstream(connection, c, "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
        { "User-Agent": "antigravity/cli/1.0.13 (aidev_client; os_type=darwin; arch=arm64)" }, "POST", { project: c.projectId });
      result.windows = (Array.isArray(usage.groups) ? usage.groups : []).flatMap((group: Json, i: number) =>
        (Array.isArray(group.buckets) ? group.buckets : []).map((bucket: Json, j: number) => {
          const period = String(bucket.window ?? "").toLowerCase();
          const fraction = number(bucket.remainingFraction ?? bucket.remaining_fraction);
          return { id: `group-${i}-${j}`, label: `${string(group.displayName ?? group.display_name) ?? "模型"} · ${["5h", "five-hour", "five_hour"].includes(period) ? "5 小時" : ["weekly", "week"].includes(period) ? "每週" : string(bucket.displayName) ?? "額度"}`,
            remainingPercent: fraction !== null ? percent(fraction * 100) : null, resetAt: instant(bucket.resetTime ?? bucket.reset_time),
            periodSeconds: ["5h", "five-hour", "five_hour"].includes(period) ? 18000 : ["weekly", "week"].includes(period) ? 604800 : null };
        }));
    } else return { ...result, status: "unsupported", message: "此帳號類型尚未提供可查詢的配額介面" };
    if (!result.windows.length) return { ...result, status: "unsupported", message: "服務商沒有提供額度視窗" };
    return result;
  }
}
