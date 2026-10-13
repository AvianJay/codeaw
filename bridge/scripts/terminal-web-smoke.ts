import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { gunzipSync } from "node:zlib";
import { chromium, expect, type Page } from "@playwright/test";
import { startTestBridge } from "../test/helpers.js";

// Build app/build/web first. Uses an isolated bridge, browser and real host shell.
const root = fileURLToPath(new URL("../../", import.meta.url));
const webRoot = path.join(root, "app/build/web");
assert.ok(fs.existsSync(path.join(webRoot, "index.html")), "Run flutter build web first");
const artifacts = path.join(root, "dist/terminal-verification");
fs.mkdirSync(artifacts, { recursive: true });
const tb = await startTestBridge({ webRoot });
const browser = await chromium.launch({ channel: process.env.CODEAW_BROWSER_CHANNEL ?? "msedge", headless: true });
const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
const errors: string[] = [];
const output = new Map<string, string>();
const opened: string[] = [];
const fonts = new Set<string>();
let initialized = 0;

function observe(page: Page) {
  page.setDefaultTimeout(20_000);
  page.on("pageerror", (error) => errors.push(error.message));
  page.on("response", (response) => {
    if (response.url().includes("assets/fonts/JetBrainsMono") && response.ok()) fonts.add(path.basename(new URL(response.url()).pathname));
  });
  page.on("websocket", (socket) => {
    const requests = new Map<number, string>();
    const parse = (payload: string | Buffer) => JSON.parse(typeof payload === "string" ? payload : gunzipSync(payload).toString());
    socket.on("framesent", ({ payload }) => {
      const message = parse(payload);
      if (message.method === "initialize") initialized++;
      if (message.method?.startsWith("_codeaw/terminal/")) requests.set(message.id, message.method);
    });
    socket.on("framereceived", ({ payload }) => {
      const message = parse(payload);
      const append = (event: any) => {
        if (event.type === "data") output.set(event.terminalId, (output.get(event.terminalId) ?? "") + event.data);
      };
      if (message.method === "_codeaw/terminal/event") append(message.params);
      if (requests.get(message.id) === "_codeaw/terminal/open" && message.result) {
        opened.push(message.result.terminalId);
        for (const event of message.result.events) append(event);
      }
      if (message.id !== undefined) requests.delete(message.id);
    });
  });
}

async function semantics(page: Page) {
  await page.locator("flt-semantics-placeholder, flt-semantics").first().waitFor({ state: "attached" });
  const placeholder = page.locator("flt-semantics-placeholder");
  if (await placeholder.count()) await placeholder.dispatchEvent("click");
}

async function focusTerminal(page: Page) {
  // Initialize xterm's custom text input through the normal canvas interaction
  // before enabling semantics for the toolbar/tab locators. Flutter's semantics
  // input strategy otherwise expects an EditableText that xterm does not use.
  await page.locator("flutter-view").click({ position: { x: 420, y: 180 } });
  await expect(page.locator(".flt-text-editing")).toBeAttached();
  await semantics(page);
}

async function command(page: Page, terminalId: string, text: string, marker: string) {
  const input = page.locator(".flt-text-editing");
  if (await input.count() === 0) await page.getByRole("button", { name: /^鍵盤(?: 鍵盤)?$/ }).click();
  await expect(input).toBeAttached();
  await input.focus();
  await input.pressSequentially(text, { delay: 5 });
  await page.keyboard.press("Enter");
  await expect.poll(() => output.get(terminalId) ?? "", { timeout: 20_000 }).toContain(marker);
}

let page = await context.newPage();
observe(page);
try {
  const launch = new URL(tb.http);
  launch.searchParams.set("pair", "");
  launch.searchParams.set("c", tb.bridge.devices.createPairingCode());
  await page.goto(launch.toString());
  // The pairing URL is cleared before pairing finishes, so wait for the saved
  // device's socket initialization instead of its temporary navigation URL.
  await expect.poll(() => initialized, { timeout: 20_000 }).toBeGreaterThan(0);
  await page.goto(`${tb.http}/#/terminal?cwd=${encodeURIComponent(tb.home)}`);
  await expect.poll(() => opened.length).toBe(1);
  await focusTerminal(page);
  const first = opened[0];
  await expect.poll(() => output.get(first) ?? "").toContain(process.platform === "win32" ? "> " : "$");
  await command(page, first, process.platform === "win32" ? "$terminalValue = 'one'; Write-Output ('edge-' + $terminalValue)" : "terminalValue=one; printf 'edge-%s\\n' \"$terminalValue\"", "edge-one");
  await page.getByRole("button", { name: "新增終端機", exact: true }).click();
  await expect.poll(() => opened.length).toBe(2);
  const second = opened[1];
  assert.notEqual(first, second);
  await command(page, second, process.platform === "win32" ? "$terminalValue = 'two'; Write-Output ('edge-' + $terminalValue)" : "terminalValue=two; printf 'edge-%s\\n' \"$terminalValue\"", "edge-two");
  const folder = path.basename(tb.home);
  await page.getByRole("checkbox", { name: new RegExp(`${folder} · 1$`) }).click();
  await command(page, first, process.platform === "win32" ? "Write-Output ('independent-' + $terminalValue)" : "printf 'independent-%s\\n' \"$terminalValue\"", "independent-one");

  output.clear();
  const count = opened.length;
  await page.reload();
  await expect.poll(() => opened.length).toBeGreaterThan(count);
  await focusTerminal(page);
  assert.equal(opened.at(-1), first);
  await expect.poll(() => output.get(first) ?? "").toContain("independent-one");
  await expect(page.getByRole("checkbox", { name: new RegExp(`${folder} · 2$`) })).toBeVisible();
  await command(page, first, process.platform === "win32" ? "Write-Output ('reload-' + $terminalValue)" : "printf 'reload-%s\\n' \"$terminalValue\"", "reload-one");
  await page.screenshot({ path: path.join(artifacts, "edge-desktop.png") });

  await page.close();
  page = await context.newPage();
  observe(page);
  const beforeReopen = opened.length;
  await page.goto(`${tb.http}/#/terminal`);
  await expect.poll(() => opened.length).toBeGreaterThan(beforeReopen);
  await focusTerminal(page);
  await expect(page.getByRole("checkbox", { name: new RegExp(`${folder} · 2$`) })).toBeVisible();
  await page.getByRole("checkbox", { name: new RegExp(`${folder} · 2$`) }).click();
  await command(page, second, process.platform === "win32" ? "Write-Output ('reopened-' + $terminalValue)" : "printf 'reopened-%s\\n' \"$terminalValue\"", "reopened-two");
  await page.setViewportSize({ width: 390, height: 844 });
  await page.mouse.move(380, 320);
  await command(page, second, process.platform === "win32" ? "Clear-Host; Write-Output ('phone-' + $terminalValue)" : "clear; printf 'phone-%s\\n' \"$terminalValue\"", "phone-two");
  await page.screenshot({ path: path.join(artifacts, "edge-phone.png") });
  await page.getByRole("button", { name: "關閉終端機 2", exact: true }).click();
  await expect(page.getByRole("checkbox", { name: new RegExp(`${folder} · 2$`) })).toHaveCount(0);
  await expect(page.getByRole("checkbox", { name: new RegExp(`${folder} · 1$`) })).toBeVisible();
  assert.ok(fonts.has("JetBrainsMono-Regular.ttf"), "The browser must load the bundled terminal font");
  assert.equal(errors.length, 0, errors.join("\n"));
  console.log("Terminal web smoke passed: real shell input, independent tabs, reload, closed-tab restore, explicit close, bundled font.");
} catch (error) {
  await page.screenshot({ path: path.join(artifacts, "edge-failure.png") });
  fs.writeFileSync(path.join(artifacts, "edge-failure.txt"), await page.locator("body").ariaSnapshot());
  throw error;
} finally {
  await browser.close();
  await tb.stop();
}
