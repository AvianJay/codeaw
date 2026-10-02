# codeaw

在手機上透過 Tailscale 使用電腦上的 **Claude Code / Codex / Kimi**（或任何 ACP agent）。

- 電腦上跑 **bridge**（Node/TypeScript）：用 [ACP](https://agentclientprotocol.com) 驅動本機 agent，**直接沿用你本機的設定**。用 `~/.claude/settings.json` 或 `~/.codex/config.toml` 設定的自訂 API 照樣能用，不需要 claude.ai／ChatGPT 帳號登入。
- 手機上用 **App**（Flutter，Android／iOS），或在手機、電腦上開啟 **Web**：串流顯示對話、工具呼叫、diff 與終端輸出，可以批准或拒絕權限、切換模式、模型與推理強度，也能附加圖片、瀏覽專案檔案、看 git diff。
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

Windows 可從 [nightly release](https://github.com/AvianJay/codeaw/releases/tag/nightly) 下載 `codeaw-bridge-windows-x64-setup.exe` 或 `codeaw-bridge-windows-arm64-setup.exe`。NSIS 安裝程式以目前使用者安裝到 `%LOCALAPPDATA%\Programs\codeaw-bridge`，提供開始選單的系統匣、配對、設定與移除捷徑；可選擇登入自動啟動及桌面捷徑。安裝完成後可直接啟動系統匣。安裝包包含 runtime，Tailscale 與 ACP agents 需另外安裝。

更新會停止 bridge 與執行中的回合；移除程式會停止 bridge 並移除登入自動啟動，保留 `~/.codeaw` 的設定、配對裝置與歷史。如果已註冊 Windows 服務，需先從管理員終端機執行 `service uninstall`，更新後再重新安裝服務。NSIS 安裝程式提供英文／繁體中文介面，也支援 `/S` 靜默安裝與 `/D=<完整安裝路徑>`（`/D` 放最後，不加引號）。

從原始碼安裝：

```powershell
cd bridge
npm install
npm run build
npm link            # 之後就能直接用 codeaw-bridge 指令（或改用 node dist/index.js）
```

第一次執行：

```powershell
codeaw-bridge init    # 建立 ~/.codeaw/config.yaml，會自動偵測已安裝的 agent
codeaw-bridge         # Windows：背景啟動並顯示系統匣；首次使用會跳出配對視窗
codeaw-bridge start   # 前景 CLI 模式；首次使用會印出配對 QR code
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

### 系統匣與背景運行

Windows 執行 `codeaw-bridge tray`（或不帶指令）後可以關掉終端機，bridge 會繼續在背景運行。重複啟動會連到同一個 bridge，同一桌面只會有一個系統匣圖示。雙擊圖示開啟配對視窗，右鍵選單提供：

- **配對手機**：QR code、可複製的網址與配對碼、五分鐘倒數、重新產生配對碼及配對成功提示。也能執行 `codeaw-bridge pair --window`。
- **設定**：連接埠、工作目錄、agent 開關與閒置時間。保留 YAML 註解及進階欄位；儲存後重啟，若新連接埠無法使用則回復原設定。也能執行 `codeaw-bridge settings`。
- **已配對裝置**、**開啟日誌**、**登入後自動啟動系統匣**、**重新啟動 bridge**。
- **關閉系統匣**：bridge 繼續運行；**停止 bridge 並退出**：停止 bridge 與 agent。

設定儲存、重啟與停止會中止正在執行的回合，視窗會先提醒。系統匣和原生視窗目前支援 Windows；Linux／macOS 使用 CLI 與服務管理。

所有平台都可使用以下指令，`--config` 可以管理不同設定檔的程序：

```powershell
codeaw-bridge start --background    # 不顯示系統匣的背景模式
codeaw-bridge status                # 執行狀態、PID、連線數與監聽地址
codeaw-bridge restart               # 重新載入設定並重啟
codeaw-bridge stop                  # 等待 bridge 正常停止
```

本機管理透過 Windows named pipe／Unix socket，沒有新增可從手機連線呼叫的管理 HTTP API。背景／服務模式不會把配對碼寫進日誌。

### Windows 防火牆

如果手機連不上，但電腦自己可以連，請用系統管理員身分允許來自 tailnet 的連線：

```powershell
New-NetFirewallRule -DisplayName "codeaw-bridge (Tailscale)" -Direction Inbound -Protocol TCP -LocalPort 7860 -RemoteAddress 100.64.0.0/10 -Action Allow
```

### 開機自動啟動

Windows 可從系統匣勾選「登入後自動啟動系統匣」，或使用指令（不需要管理員權限）：

```powershell
codeaw-bridge autostart install
codeaw-bridge autostart status
codeaw-bridge autostart uninstall
```

登入啟動採用使用者的 Windows Run 登錄項目，以隱藏視窗啟動，會沿用本機設定；若 bridge 已由服務啟動，登入時只附加系統匣。舊的 `bridge/scripts/autostart.ps1` 保留為相容入口，也會移除舊版登入排程。

### 服務模式

```powershell
codeaw-bridge service install
codeaw-bridge service start
codeaw-bridge service status
codeaw-bridge service restart
codeaw-bridge service stop
codeaw-bridge service uninstall
```

- **Windows**：使用真正的 Windows SCM 服務，延遲自動啟動、異常退出時重啟；安裝前先停止既有 bridge。安裝／管理需管理員終端機，安裝時會在本機要求目前 Windows 帳號的密碼（非 Windows Hello PIN），讓服務沿用該帳號的 agent 設定與權限。密碼由 Windows 服務管理保存，bridge 不會寫入檔案或日誌。若帳號密碼變更，需更新服務登入設定。服務 host 使用 Windows 內建 .NET Framework 編譯；更新 host 時先移除再安裝。
- **Linux**：使用 `systemd --user`。安裝後再執行 `service start`；若需要尚未登入或登出後持續運行，啟用該使用者的 lingering（`loginctl enable-linger <使用者>`）。日誌使用 user journal：`journalctl --user -u 'codeaw-bridge-*'`。
- **macOS**：使用使用者的 LaunchAgent，登入時啟動；安裝後可執行 `service start` 立即啟動。

Windows 服務在沒有登入桌面時也能運行。登入後執行 `codeaw-bridge tray` 或啟用登入系統匣，就能管理同一個服務中的 bridge；系統匣從登入桌面啟動，符合 Windows 的[服務與互動桌面分離機制](https://learn.microsoft.com/en-us/windows/win32/services/interactive-services)。

背景程序、Windows 服務與 macOS LaunchAgent 的紀錄寫在設定檔旁的 `bridge.log`（預設 `~/.codeaw/bridge.log`）；系統匣錯誤寫在 `desktop.log`，登入啟動錯誤寫在 `desktop-launch.log`。`bridge.log` 超過 5 MiB 時在下次背景／Windows 服務啟動前保留一份 `.1` 備份。各 agent 的 stderr 寫在 `~/.codeaw/data/logs/`。

### （選用）HTTPS／wss

原生 App 預設直接走 `ws://100.x.y.z:7860`，WireGuard 已經加密。也可以執行 `tailscale serve --bg 7860`，再把 App 的網址改成 `wss://<電腦>.<tailnet>.ts.net/acp`。Web 使用同一個 HTTPS 網址，頁面、API 與 WebSocket 都由 bridge 提供。

## 2. 手機端（App）

Android 使用下列 APK 安裝方式。iPhone／iPad（iOS 13+）可從 nightly 下載 `codeaw-ios-unsigned.ipa`，以自己的簽署／側載工具重新簽署後安裝。Unsigned IPA 沒有 Apple 簽章或 provisioning profile，無法直接點開安裝，也不是 App Store／TestFlight 發行包。

1. 安裝 Tailscale App，並登入同一個 tailnet。
2. 安裝 codeaw App：[nightly release](https://github.com/AvianJay/codeaw/releases/tag/nightly) 的 `codeaw-arm64-v8a.apk` 或 `codeaw-universal.apk`（或用 `cd app && flutter build apk --release --split-per-abi` 自己建置）。
3. 在電腦上執行 `codeaw-bridge pair`，用 App 的「掃描 QR code」掃終端機上的 QR。也可以手動輸入網址與配對碼；配對碼 5 分鐘內有效，只能用一次。

使用小提示：

- 回合進行中還可以繼續輸入。agent 支援插話（新版 Claude／Codex）時，訊息會直接插進目前的回合；不支援時（Kimi）會排在目前回合之後。長按送出鍵＝一律排隊。
- 對話底部會顯示思考、回覆或工具執行狀態，以及這一輪已處理多久（包含等待批准／回覆的時間）。重新連線後會接續計時，下一輪開始時歸零。
- 輸入框上方的 chip 可以切換模式、模型與推理強度。Claude 的「Manual」模式會在每個危險操作前詢問；`dontAsk` 會直接拒絕沒有預先允許的工具。
- 右上角可以瀏覽專案檔案，或查看 git 變更與 diff。
- 「從電腦重新載入歷史」：如果你在終端機上又繼續聊了同一個 session，用這個重新同步。

### 推播（App 沒開時）

`codeaw-bridge init` 會產生一個隨機的 ntfy topic。在手機安裝 [ntfy](https://ntfy.sh)，然後在 App 的「設定 → 推播通知」點「在 ntfy App 訂閱」。之後當**沒有任何裝置連著**、而 agent 需要批准或已經做完時，就會收到推播，點一下會直接打開那個對話。

推播內容預設只有「Claude Code 需要你的批准／已完成」，不會帶出對話內容（ntfy.sh 是公開的中繼伺服器）。要顯示 session 標題，請設定 `includeDetails: true`，或在 tailnet 內自架 ntfy。

App 在背景但仍保持連線時，則由 App 自己跳本機通知。

## 開發

### Web（手機與電腦）

Nightly 的 bridge 安裝包與可攜式壓縮檔已附上 `web/`。可攜式版解壓縮時請保留執行檔旁的 `web/` 資料夾；另外提供 `codeaw-web.tar.gz`。

1. 啟動 bridge，執行 `tailscale serve --bg 7860`（自訂 port 請改成實際值）。
2. 在已連上同一個 tailnet 的手機或電腦，用瀏覽器開啟 Tailscale 顯示的 `https://<電腦>.<tailnet>.ts.net/`。
3. 在電腦執行 `codeaw-bridge pair`，把配對碼輸入網頁。Bridge 網址會自動填入；HTTPS 下也能掃描原生 App 使用的配對 QR code。
4. iPhone／iPad 可在 Safari 選「加入主畫面」。Android、Windows、macOS 和 Linux 也可直接使用瀏覽器。

Web 的配對保存在目前瀏覽器與 origin；相機與加密儲存需要 HTTPS（本機開發可用 `http://localhost:7860`）。頁面可公開載入，但 session、檔案與終端機仍需有效的裝置 token。瀏覽器不使用原生 App 的本機通知；在背景或關閉頁面時，通知仍透過 bridge 的 ntfy 設定傳送。

從原始碼建置並由 bridge 提供頁面：

```powershell
cd bridge
npm install
npm run build:web   # 需要 Flutter；產生 app/build/web 並複製到 bridge/dist/web
npm run build
npm start -- start
```

`npm run build:bin` 會把已建置的 `dist/web` 複製到執行檔旁；若也要打包 Web，請先執行 `npm run build:web`。開發時 `npm run dev -- start` 也能直接使用 `app/build/web`。

### Nightly 建置

GitHub Actions 的 [Build nightly](.github/workflows/build.yml) 會在 `master` push、每日台灣時間 02:00，或手動執行時建置。所有建置成功後，首次建立 `nightly` prerelease，之後只移動同一個 tag 並更新同一個 release、附件及 `SHA256SUMS`。

在 repository 的 Actions secrets 設定 `KEYSTORE_BASE64`（keystore 的 Base64）、`KEYSTORE_ALIAS`、`KEYSTORE_PASSWORD`。密碼同時用於 keystore 與 key；CI 缺少任何一項會失敗。Android 會產出已簽章的 universal APK、三個 ABI APK 與 AAB，版本編號使用 workflow run number。

Bridge 會將 `bridge/package.json` 的所有 `bin` 打包成 Windows、Linux（glibc／musl）與 macOS 的 x64／ARM64 執行檔。執行檔內含 runtime，不需另外安裝 Node 或 Bun；Tailscale 與 ACP agents 仍需另外安裝。Windows 附件提供 NSIS `*-setup.exe` 與可攜式 ZIP，其餘為 tar.gz，全部列入 `SHA256SUMS`。

Web 先建置，再附入所有 bridge 發行包與 Windows 安裝程式。iOS 在 macOS runner 執行 `flutter build ios --release --no-codesign`，把 `Runner.app` 放進 `Payload/` 壓縮成 `codeaw-ios-unsigned.ipa`，不需要 Apple 簽署 secrets。本機 iOS 建置需 macOS／Xcode，也可以用相同方式打包。

本機已安裝 Bun 1.4.2 或更新版本時，可在 `bridge` 執行 `npm run build:bin`，或用 `npm run build:bin -- --target=bun-linux-arm64` 交叉建置，輸出位於 `bridge/dist/bin`。本機 Android 建置若未設定 `KEYSTORE_PATH`、`KEYSTORE_ALIAS`、`KEYSTORE_PASSWORD`，會沿用 debug 簽章。

建置 Windows NSIS 安裝程式另需 [NSIS 3.09+](https://nsis.sourceforge.io/Download)（建議使用最新版）；Windows 安裝 NSIS，Linux 可安裝 `nsis` 套件。預設會先建置對應的 Windows 執行檔，再產生安裝包：

```powershell
cd bridge
npm run build:installer -- --arch=x64
npm run build:installer -- --arch=arm64
# 重用已建置的 dist/bin/codeaw-bridge.exe（會檢查 PE 架構）：
npm run build:installer -- --skip-build --arch=x64
# 自訂 compiler 路徑；也可設定 MAKENSIS：
npm run build:installer -- --skip-build --makensis="C:\Program Files (x86)\NSIS\makensis.exe"
```

輸出為 `bridge/dist/installer/codeaw-bridge-windows-<架構>-setup.exe`；`--bin-dir`、`--out-dir` 可指定輸入與輸出資料夾。Nightly 會在 Linux runner 交叉建置 x64／ARM64 安裝包。

`npm run smoke:installer` 會在 Windows 使用臨時安裝資料夾與獨立 `CODEAW_HOME`，測試靜默安裝、停止執行中的 bridge 後更新、捷徑、登入項目清理與設定保留；若目前帳號已有安裝或捷徑則拒絕覆蓋。CI 也會在 Windows runner 執行此測試，通過後才發布 nightly。

```powershell
cd bridge
npm test                 # vitest：用腳本化的假 agent，不花 token
npm run typecheck
npm run smoke            # 對本機真的 agent 做握手 / 列 session / 開 session（不送 prompt）
npm run smoke:desktop    # Windows：隔離設定渲染三個原生視窗、編譯服務 host；不安裝服務／自動啟動
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
