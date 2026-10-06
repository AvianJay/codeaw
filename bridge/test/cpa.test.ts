import { describe, expect, it } from "vitest";
import { CpaUsageService, codexWindows, claudeWindows, resetCount, grokWindows, cpaConnection } from "../src/server/cpa.js";
import { startTestBridge, TestClient } from "./helpers.js";

const params = { endpoint: "https://cpa.example.com/proxy", managementKey: "test-management-secret" };
const reset = 1791284400;
const usage = { plan_type: "team", rate_limit: {
  primary_window: { used_percent: 25, reset_at: reset, limit_window_seconds: 18000 },
  secondary_window: { used_percent: 4, reset_at: reset + 604800, limit_window_seconds: 604800 },
} };

describe("CPA read-only management adapter", () => {
  it("normalizes roots, prefixes, and explicit v8 URLs without embedding credentials", () => {
    expect(cpaConnection(params).base.href).toBe("https://cpa.example.com/proxy/v0/management");
    expect(cpaConnection({ ...params, endpoint: "https://cpa.example.com/v8/management/" }).base.href).toBe("https://cpa.example.com/v8/management");
    expect(cpaConnection({ ...params, endpoint: "http://localhost:8317/management.html" }).base.pathname).toBe("/v0/management");
    for (const endpoint of ["file:///secret", "https://user:secret@cpa.example.com", "https://cpa.example.com?key=secret", "https://cpa.example.com#key"]) {
      expect(() => cpaConnection({ ...params, endpoint })).toThrow();
    }
    expect(() => cpaConnection({ ...params, managementKey: "" })).toThrow(/Management Key/);
  });

  it("classifies reversed and monthly Codex windows; unknown is never zero", () => {
    const reversed = codexWindows({ rate_limit: { allowed: false,
      primary_window: { used_percent: 13, limit_window_seconds: 604800 },
      secondary_window: { limit_window_seconds: 18000 },
    } });
    expect(reversed[0]).toMatchObject({ id: "weekly", remainingPercent: 87 });
    expect(reversed[1]).toMatchObject({ id: "five-hour", remainingPercent: null, resetAt: null });
    expect(codexWindows({ rate_limit: { secondary_window: { used_percent: 2, limit_window_seconds: 2592000 } } })[0]).toMatchObject({ id: "monthly", label: "每月", remainingPercent: 98 });
    expect(codexWindows({ rateLimit: { primaryWindow: { usedPercent: "150", resetAfterSeconds: 60 } } }, 1700000000000)[0]).toMatchObject({ remainingPercent: 0, resetAt: "2023-11-14T22:14:20.000Z" });
  });

  it("parses Claude ISO timestamps, Grok credits, and only available unexpired reset credits", () => {
    expect(claudeWindows({ five_hour: { utilization: 0, resets_at: "2026-10-06T01:00:00Z" }, seven_day: { utilization: 63 } })).toMatchObject([
      { id: "five-hour", remainingPercent: 100, resetAt: "2026-10-06T01:00:00.000Z" }, { id: "weekly", remainingPercent: 37, resetAt: null },
    ]);
    expect(grokWindows({ config: { creditUsagePercent: 30, currentPeriod: { type: "weekly", end: "2026-10-09T12:00:00Z" } } })[0]).toMatchObject({ id: "weekly", remainingPercent: 70 });
    expect(resetCount({ available_count: 0 })).toBe(0);
    expect(resetCount({})).toBeNull();
    expect(resetCount({ credits: [
      { reset_type: "codex_rate_limits", status: "available", expires_at: "2026-10-20T00:00:00Z" },
      { reset_type: "codex_rate_limits", status: "used", expires_at: "2026-10-20T00:00:00Z" },
      { reset_type: "codex_rate_limits", status: "available", expires_at: "2026-09-20T00:00:00Z" },
    ] }, Date.parse("2026-10-05T00:00:00Z"))).toBe(1);
  });

  it("lists providers, never returns auth secrets, and queries live usage plus reset counts", async () => {
    const calls: { url: string; body?: any }[] = [];
    const fetchImpl: typeof fetch = async (input, init) => {
      const url = String(input), body = init?.body ? JSON.parse(String(init.body)) : undefined;
      calls.push({ url, body });
      expect(new Headers(init?.headers).get("Authorization")).toBe("Bearer test-management-secret");
      if (url.endsWith("/auth-files")) return Response.json({ files: [{ name: "codex-user.json", email: "user@example.com", type: "codex", auth_index: "7", id_token: { chatgpt_account_id: "account-7" }, access_token: "NEVER_RETURN", account: "ALSO_SECRET", success: 32, failed: 0 }] });
      expect(body.authIndex).toBe("7");
      expect(body.method).toBe("GET");
      expect(body.header.Authorization).toBe("Bearer $TOKEN$");
      return Response.json({ status_code: 200, body: JSON.stringify(body.url.includes("reset-credits") ? { available_count: 1 } : body.url.includes("subscriptions") ? { active_until: "2026-10-25T00:00:00Z" } : usage) });
    };
    const service = new CpaUsageService(fetchImpl);
    const list = await service.accounts(params);
    expect(JSON.stringify(list)).not.toMatch(/NEVER_RETURN|ALSO_SECRET|access_token|auth_index/);
    const account = list.accounts[0];
    expect(account).toMatchObject({ provider: "codex", label: "user@example.com", requests: 32 });
    const quota = await service.quota({ ...params, accountId: account.id });
    expect(quota).toMatchObject({ status: "ok", resetsRemaining: 1, plan: "team", subscriptionUntil: "2026-10-25T00:00:00.000Z" });
    expect(quota.windows).toMatchObject([{ remainingPercent: 75 }, { remainingPercent: 96 }]);
    expect(calls.filter(c => c.body).every(c => c.url.endsWith("/api-call") && !c.body.url.includes("consume"))).toBe(true);
  });

  it("uses v8 paths and preserves usage when optional reset credits fail", async () => {
    const p = { ...params, endpoint: "https://cpa.example.com/v8/management" };
    const service = new CpaUsageService(async (input, init) => {
      const url = String(input);
      if (url.endsWith("/credentials")) return Response.json({ files: [{ name: "a", type: "codex", auth_index: 0 }] });
      expect(url).toMatch(/\/v8\/management\/requests\/api-call$/);
      const body = JSON.parse(String(init?.body));
      return Response.json({ status_code: body.url.includes("reset-credits") ? 404 : 200, body: usage });
    });
    const list = await service.accounts(p);
    expect(await service.quota({ ...p, accountId: list.accounts[0].id })).toMatchObject({ status: "ok", resetsRemaining: null });
  });

  it("does not query disabled or unsupported accounts, leak upstream bodies, or follow redirects", async () => {
    let quotaCalls = 0;
    const service = new CpaUsageService(async (_, init) => {
      expect(init?.redirect).toBe("error");
      if (init?.method === "POST") quotaCalls++;
      return Response.json({ files: [{ name: "disabled", type: "claude", disabled: true, auth_index: "a" }, { name: "custom", type: "custom", auth_index: "b" }] });
    });
    const list = await service.accounts(params);
    expect((await service.quota({ ...params, accountId: list.accounts[0].id })).status).toBe("disabled");
    expect((await service.quota({ ...params, accountId: list.accounts[1].id })).status).toBe("unsupported");
    expect(quotaCalls).toBe(0);
    const denied = new CpaUsageService(async () => new Response('secret: test-management-secret', { status: 401 }));
    await expect(denied.accounts(params)).rejects.toThrow(/認證失敗/);
    await expect(denied.accounts(params)).rejects.not.toThrow(/test-management-secret/);
  });

  it("exposes the feature only on a paired ACP connection", async () => {
    const bridge = await startTestBridge({ fetchImpl: async () => Response.json({ files: [{ name: "grok.json", type: "xai", email: "grok@example.com" }] }) });
    const client = await TestClient.connect(bridge.url, bridge.tokenFor("usage-viewer"));
    try {
      const list = await client.request<any>("_codeaw/cpa/accounts", params);
      expect(list.accounts[0]).toMatchObject({ provider: "grok", label: "grok@example.com" });
    } finally { client.close(); await bridge.stop(); }
  });

  it("shares concurrent account and Claude quota requests and limits profile/usage polling", async () => {
    let now = Date.parse("2026-10-06T00:00:00Z"), lists = 0, queries = 0, profiles = 0;
    const service = new CpaUsageService(async (input, init) => {
      if (String(input).endsWith("/auth-files")) { lists++; return Response.json({ files: [{ name: "claude", type: "claude", auth_index: "c" }] }); }
      const body = JSON.parse(String(init?.body));
      if (body.url.endsWith("/profile")) { profiles++; return Response.json({ status_code: 200, body: { account: { has_claude_pro: true } } }); }
      queries++;
      await new Promise(resolve => setTimeout(resolve, 10));
      return Response.json({ status_code: 200, body: { five_hour: { utilization: 23 }, seven_day: { utilization: 4 } } });
    }, () => now);
    const [first, second] = await Promise.all([service.accounts(params), service.accounts(params)]);
    expect(lists).toBe(1); expect(second).toEqual(first);
    const p = { ...params, accountId: first.accounts[0].id };
    const results = await Promise.all([service.quota(p), service.quota(p), service.quota(p)]);
    expect(queries).toBe(1); expect(profiles).toBe(1);
    expect(results.every(q => q.status === "ok" && q.plan === "Pro")).toBe(true);
    now += 30_000;
    await service.accounts(params); await service.quota(p);
    expect(lists).toBe(2); expect(queries).toBe(1);
    now += 270_000; await service.quota(p);
    expect(queries).toBe(2); expect(profiles).toBe(1);
  });

  it("honors embedded Retry-After, keeps last successful quota stale, and recovers after cooldown", async () => {
    let now = Date.parse("2026-10-06T00:00:00Z"), limited = false, queries = 0;
    const service = new CpaUsageService(async (input, init) => {
      if (String(input).endsWith("/auth-files")) return Response.json({ files: [{ name: "claude", type: "claude", auth_index: "c" }] });
      const body = JSON.parse(String(init?.body));
      if (body.url.endsWith("/profile")) return Response.json({ status_code: 200, body: {} });
      queries++;
      return Response.json(limited ? { status_code: 429, header: { "Retry-After": ["120"] }, body: "PRIVATE UPSTREAM SECRET" }
        : { status_code: 200, body: { five_hour: { utilization: 23 } } });
    }, () => now);
    const p = { ...params, accountId: (await service.accounts(params)).accounts[0].id };
    const ok = await service.quota(p);
    now += 300_000; limited = true;
    const stale = await service.quota(p);
    expect(stale).toMatchObject({ status: "stale", windows: ok.windows, checkedAt: ok.checkedAt, retryAt: new Date(now + 120_000).toISOString() });
    expect(JSON.stringify(stale)).not.toMatch(/PRIVATE|test-management-secret/);
    now += 30_000;
    expect(await service.quota(p)).toEqual(stale); expect(queries).toBe(2);
    now += 90_000; limited = false;
    const recovered = await service.quota(p);
    expect(recovered.status).toBe("ok"); expect(recovered.checkedAt).not.toBe(ok.checkedAt);
    expect(recovered.retryAt).toBeUndefined(); expect(queries).toBe(3);
  });

  it("backs off repeated 429s without a header and applies cooldown to distinct Claude accounts only", async () => {
    let now = Date.parse("2026-10-06T00:00:00Z"), queries = 0;
    const service = new CpaUsageService(async (input) => {
      if (String(input).endsWith("/auth-files")) return Response.json({ files: [
        { name: "c1", type: "claude", auth_index: "a" }, { name: "c2", type: "claude", auth_index: "b" },
        { name: "codex", type: "codex", auth_index: "d" },
      ] });
      queries++; return Response.json({ status_code: 429, body: "PRIVATE" });
    }, () => now);
    const accounts = (await service.accounts(params)).accounts;
    const p = { ...params, accountId: accounts[0].id };
    expect(await service.quota(p)).toMatchObject({ status: "error", windows: [], retryAt: new Date(now + 60_000).toISOString() });
    await service.quota({ ...params, accountId: accounts[1].id });
    expect(queries).toBe(1);
    now += 60_000;
    expect((await service.quota(p)).retryAt).toBe(new Date(now + 120_000).toISOString());
    expect(queries).toBe(2);
    await service.quota({ ...params, accountId: accounts[2].id });
    expect(queries).toBeGreaterThan(2);
  });

  it("accepts HTTP-date Retry-After and isolates quotas by management endpoint and key", async () => {
    const now = Date.parse("2026-10-06T00:00:00Z"); let queries = 0;
    const service = new CpaUsageService(async (input) => {
      if (String(input).endsWith("/auth-files")) return Response.json({ files: [{ name: "claude", type: "claude", auth_index: "c" }] });
      queries++; return new Response("PRIVATE", { status: 429, headers: { "Retry-After": new Date(now + 180_000).toUTCString() } });
    }, () => now);
    const accountId = (await service.accounts(params)).accounts[0].id;
    expect((await service.quota({ ...params, accountId })).retryAt).toBe(new Date(now + 180_000).toISOString());
    await service.quota({ ...params, accountId }); expect(queries).toBe(1);
    await service.quota({ ...params, accountId, managementKey: "other-key" }); expect(queries).toBe(2);
    await service.quota({ ...params, accountId, endpoint: "https://other.example.com" }); expect(queries).toBe(3);
  });

  it("paces successful Claude requests for distinct accounts", async () => {
    const starts: number[] = [];
    const service = new CpaUsageService(async (input, init) => {
      if (String(input).endsWith("/auth-files")) return Response.json({ files: [
        { name: "a", type: "claude", auth_index: "a" }, { name: "b", type: "claude", auth_index: "b" },
      ] });
      if (JSON.parse(String(init?.body)).url.endsWith("/usage")) starts.push(Date.now());
      return Response.json({ status_code: 200, body: { five_hour: { utilization: 23 } } });
    });
    const accounts = (await service.accounts(params)).accounts;
    const results = await Promise.all(accounts.map(account => service.quota({ ...params, accountId: account.id })));
    expect(results.every(result => result.status === "ok")).toBe(true);
    expect(starts).toHaveLength(2); expect(starts[1] - starts[0]).toBeGreaterThanOrEqual(900);
  });

  it("also cools down account-list 429s without losing a previously successful snapshot", async () => {
    let now = Date.parse("2026-10-06T00:00:00Z"), lists = 0, limited = false, queries = 0;
    const service = new CpaUsageService(async (input, init) => {
      if (String(input).endsWith("/auth-files")) {
        lists++;
        if (limited) return new Response("PRIVATE", { status: 429, headers: { "Retry-After": "120" } });
        return Response.json({ files: [{ name: "claude", type: "claude", auth_index: "a" }] });
      }
      queries++;
      return Response.json({ status_code: 200, body: JSON.parse(String(init?.body)).url.endsWith("/usage") ? { five_hour: { utilization: 23 } } : {} });
    }, () => now);
    const list = await service.accounts(params), p = { ...params, accountId: list.accounts[0].id };
    const ok = await service.quota(p);
    now += 30_000; limited = true;
    expect(await service.accounts(params)).toEqual(list);
    expect(await service.quota(p)).toMatchObject({ status: "stale", windows: ok.windows, checkedAt: ok.checkedAt, retryAt: new Date(now + 120_000).toISOString() });
    now += 30_000; await service.accounts(params); await service.quota(p);
    expect(lists).toBe(2); expect(queries).toBe(2);
    now += 90_000; limited = false;
    expect((await service.accounts(params)).checkedAt).not.toBe(list.checkedAt);
    expect((await service.quota(p)).status).toBe("ok");
    expect(lists).toBe(3);
  });
});
