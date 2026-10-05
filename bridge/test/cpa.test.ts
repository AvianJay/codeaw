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
});
