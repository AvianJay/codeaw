# codeaw

在手機上透過 Tailscale 使用電腦上的 **Claude Code / Codex / Kimi**（或任何 ACP agent）。

- 電腦上跑 **bridge**（Node/TypeScript）：用 [ACP](https://agentclientprotocol.com) 驅動本機 agent，**直接沿用你本機的設定**。用 `~/.claude/settings.json` 或 `~/.codex/config.toml` 設定的自訂 API 照樣能用，不需要 claude.ai／ChatGPT 帳號登入。
- 手機上用 **App**（Flutter，Android）：串流顯示對話、工具呼叫、diff 與終端輸出，可以批准或拒絕權限、切換模式、模型與推理強度，也能附加圖片、瀏覽專案檔案、看 git diff。
- **斷線不中斷**：手機斷線或 App 被關掉時，agent 照樣工作，權限請求會等你回來。重新連上後只補傳漏掉的部分；同一個對話可以同時開在多台裝置上。
- **接續電腦上既有的對話**：你在終端機開過的 Claude Code／Codex session 都會出現在 App 的清單裡。
- **互動終端機**：從首頁、對話或檔案頁的終端機按鈕，在電腦上的工作目錄操作 shell。支援彩色輸出、中文輸入、貼上、Ctrl+C、Tab 與方向鍵；離開畫面仍保留 shell，十分鐘未查看後自動關閉。

```
Android App ══ WebSocket（ACP + codeaw 擴充）══▶ bridge（電腦）══ stdio / ACP ══▶ claude-agent-acp / codex-acp / kimi acp
      ▲              經 Tailscale                     │
      └──────── ntfy 推播（沒有任何裝置連著時）◀──────┘
```

技術細節見 [docs/protocol.md](docs/protocol.md)。

## 1. 電腦端（bridge）

需求：Node ≥ 22、[Tailscale](https://tailscale.com/download)，以及要用的 agent 的 ACP adapter：

```powershell
npm i -g @agentclientprotocol/claude-agent-acp    # Claude Code
npm i -g @agentclientprotocol/codex-acp           # Codex
# Kimi Code 自帶 `kimi acp`
```

安裝 bridge：

```powershell
cd bridge
npm install
npm run build
npm link            # 之後就能直接用 codeaw-bridge 指令（或改用 node dist/index.js）
```

第一次執行：

```powershell
codeaw-bridge init    # 建立 ~/.codeaw/config.yaml，會自動偵測已安裝的 agent
codeaw-bridge         # 啟動 bridge；還沒有配對過的裝置時，會直接印出配對 QR code
```

`~/.codeaw/config.yaml` 重點：

| 設定 | 說明 |
|---|---|
| `listen.hosts: auto` | 只綁這台電腦的 Tailscale IP 與 127.0.0.1，**不會**對區網開放 |
| `listen.port` | 預設 7860 |
| `workspaces` | 手機可以瀏覽、也可以在這些資料夾開新對話（已有 session 的資料夾一律允許） |
| `agents.<id>.env` | 額外環境變數，例如給某個 agent 指定不同的 `ANTHROPIC_BASE_URL` |
| `notifications.ntfy` | 推播設定，見下方 |
| `idleSessionCloseMinutes` / `idleAgentStopMinutes` | 閒置多久後釋放 agent 資源（需要時會自動恢復） |

其他指令：`codeaw-bridge pair`（再配對一台裝置）、`codeaw-bridge devices`（列出已配對裝置）、`codeaw-bridge revoke <id>`（撤銷裝置）。

### Windows 防火牆

如果手機連不上，但電腦自己可以連，請用系統管理員身分允許來自 tailnet 的連線：

```powershell
New-NetFirewallRule -DisplayName "codeaw-bridge (Tailscale)" -Direction Inbound -Protocol TCP -LocalPort 7860 -RemoteAddress 100.64.0.0/10 -Action Allow
```

### 開機自動啟動

```powershell
powershell -ExecutionPolicy Bypass -File bridge\scripts\autostart.ps1          # 登入時自動在背景啟動
powershell -ExecutionPolicy Bypass -File bridge\scripts\autostart.ps1 -Remove  # 移除
```

紀錄寫在 `~/.codeaw/bridge.log`，各 agent 的 stderr 寫在 `~/.codeaw/data/logs/`。

### （選用）HTTPS／wss

預設直接走 `ws://100.x.y.z:7860`，WireGuard 已經加密。若想用 MagicDNS + HTTPS，可以執行 `tailscale serve --bg 7860`，再把 App 的網址改成 `wss://<電腦>.<tailnet>.ts.net/acp`。不過 Tailscale Serve 對 WebSocket 有不穩的回報，不建議當成預設。

## 2. 手機端（App）

1. 安裝 Tailscale App，並登入同一個 tailnet。
2. 安裝 codeaw App：[nightly release](https://github.com/AvianJay/codeaw/releases/tag/nightly) 的 `codeaw-arm64-v8a.apk` 或 `codeaw-universal.apk`（或用 `cd app && flutter build apk --release --split-per-abi` 自己建置）。
3. 在電腦上執行 `codeaw-bridge pair`，用 App 的「掃描 QR code」掃終端機上的 QR。也可以手動輸入網址與配對碼；配對碼 5 分鐘內有效，只能用一次。

使用小提示：

- 回合進行中還可以繼續輸入。agent 支援插話（新版 Claude／Codex）時，訊息會直接插進目前的回合；不支援時（Kimi）會排在目前回合之後。長按送出鍵＝一律排隊。
- 輸入框上方的 chip 可以切換模式、模型與推理強度。Claude 的「Manual」模式會在每個危險操作前詢問；`dontAsk` 會直接拒絕沒有預先允許的工具。
- 右上角可以瀏覽專案檔案，或查看 git 變更與 diff。
- 「從電腦重新載入歷史」：如果你在終端機上又繼續聊了同一個 session，用這個重新同步。

### 推播（App 沒開時）

`codeaw-bridge init` 會產生一個隨機的 ntfy topic。在手機安裝 [ntfy](https://ntfy.sh)，然後在 App 的「設定 → 推播通知」點「在 ntfy App 訂閱」。之後當**沒有任何裝置連著**、而 agent 需要批准或已經做完時，就會收到推播，點一下會直接打開那個對話。

推播內容預設只有「Claude Code 需要你的批准／已完成」，不會帶出對話內容（ntfy.sh 是公開的中繼伺服器）。要顯示 session 標題，請設定 `includeDetails: true`，或在 tailnet 內自架 ntfy。

App 在背景但仍保持連線時，則由 App 自己跳本機通知。

## 開發

### Nightly 建置

GitHub Actions 的 [Build nightly](.github/workflows/build.yml) 會在 `master` push、每日台灣時間 02:00，或手動執行時建置。所有建置成功後，首次建立 `nightly` prerelease，之後只移動同一個 tag 並更新同一個 release、附件及 `SHA256SUMS`。

在 repository 的 Actions secrets 設定 `KEYSTORE_BASE64`（keystore 的 Base64）、`KEYSTORE_ALIAS`、`KEYSTORE_PASSWORD`。密碼同時用於 keystore 與 key；CI 缺少任何一項會失敗。Android 會產出已簽章的 universal APK、三個 ABI APK 與 AAB，版本編號使用 workflow run number。

Bridge 會將 `bridge/package.json` 的所有 `bin` 打包成 Windows、Linux（glibc／musl）與 macOS 的 x64／ARM64 執行檔。執行檔內含 runtime，不需另外安裝 Node 或 Bun；Tailscale 與 ACP agents 仍需另外安裝。Windows 附件為 ZIP，其餘為 tar.gz。

本機已安裝 Bun 1.4.2 或更新版本時，可在 `bridge` 執行 `npm run build:bin`，或用 `npm run build:bin -- --target=bun-linux-arm64` 交叉建置，輸出位於 `bridge/dist/bin`。本機 Android 建置若未設定 `KEYSTORE_PATH`、`KEYSTORE_ALIAS`、`KEYSTORE_PASSWORD`，會沿用 debug 簽章。

```powershell
cd bridge
npm test                 # vitest：用腳本化的假 agent，不花 token
npm run typecheck
npm run smoke            # 對本機真的 agent 做握手 / 列 session / 開 session（不送 prompt）
npx tsx scripts/dev-bridge.ts --host 0.0.0.0 --port 7861   # 只有假 agent 的 bridge，方便調 UI

cd ../app
flutter test                                              # 單元測試 + 端對端測試（會自動起 dev bridge）
$env:CODEAW_SCREENSHOTS=1; flutter test --update-goldens test/screenshot_test.dart   # 主要畫面截圖 → test/screenshots/
```

在 bridge 執行 `npx tsx scripts/make-fixture.ts` 會重新產生 `app/test/fixtures/replay.json`，用來檢查兩件事是否一致：完整重播（壓縮後的歷史）與逐筆事件，在 App 端歸併出來的畫面要一模一樣。

## 注意

- Anthropic 條款不允許第三方程式透過 Claude 訂閱帳號（claude.ai OAuth）轉發請求。如果你用的中轉服務是走 API key，就沒有這個問題。
- 協定是 ACP v1 加上 `_meta.codeaw` / `_codeaw/*` 擴充，所以一般的 ACP 客戶端也能連上 bridge。日後 agent 升到 ACP v2 時，會由 bridge 負責轉譯。

## 授權

Copyright (C) 2026 AvianJay

本專案以 [GNU General Public License v3.0](LICENSE)（或任何更新的版本）授權。你可以自由使用、修改、散布；散布修改後的版本時，必須同樣以 GPL-3.0 公開原始碼。
