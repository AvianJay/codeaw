# codeaw

在手機上透過 Tailscale 使用電腦上的 **Claude Code / Codex / Kimi / Hermes Agent / DeepSeek Harness / Google Antigravity**（或任何 ACP agent）。

- 電腦上跑 **bridge**（Node/TypeScript）：用 [ACP](https://agentclientprotocol.com) 驅動本機 agent，**直接沿用你本機的設定**。用 `~/.claude/settings.json` 或 `~/.codex/config.toml` 設定的自訂 API 照樣能用，不需要 claude.ai／ChatGPT 帳號登入。
- 手機上用 **App**（Flutter，Android／iOS），或在手機、電腦上開啟 **Web**：串流顯示對話、工具呼叫、diff 與終端輸出，可以批准或拒絕權限、切換模式、模型與推理強度，也能附加圖片、用 `@` 提及專案檔案、瀏覽專案檔案、看 git diff。
- **斷線不中斷**：手機斷線或 App 被關掉時，agent 照樣工作，權限請求會等你回來。重新連上後只補傳漏掉的部分；同一個對話可以同時開在多台裝置上。
- **歷史快取**：重開 App 先還原已保存的聊天與清單，再同步新訊息；完整重同步期間保留畫面。大型工具輸出在展開時讀取完整內容，降低長聊天初次載入量。本機每台電腦最多保存 32 份快照、128 MiB，設定中可清除；圖片與檔案參照保留，讀取原始內容仍需連上 bridge。
- **接續電腦上既有的對話**：你在終端機開過的 Claude Code／Codex session 都會出現在 App 的清單裡。
- **Windows Codex 桌面同步**：載入桌面 app 持有的 Codex 對話時，bridge 會附加到桌面 owner，雙向同步訊息、工具進度與回合狀態；手機也能插話、停止、批准操作及回覆一般問題。
- **互動終端機**：從首頁、對話或檔案頁的終端機按鈕，在電腦上的工作目錄操作 shell。支援彩色輸出、中文輸入、貼上、Ctrl+C、Tab 與方向鍵；離開畫面仍保留 shell，十分鐘未查看後自動關閉。

```
Android App ══ WebSocket（ACP + codeaw 擴充）══▶ bridge（電腦）══ stdio / ACP ══▶ claude-agent-acp / codex-acp / kimi acp / hermes acp / dsh --profile acp / agy_acp_server
      ▲              經 Tailscale                     │
      └──────── ntfy 推播（沒有任何裝置連著時）◀──────┘
```

技術細節見 [docs/protocol.md](docs/protocol.md)。

## 1. 電腦端（bridge）

需求：[Tailscale](https://tailscale.com/download)，以及要用的 agent 的 ACP adapter。下列 npm 安裝方式與從原始碼執行 bridge 需要 Node ≥ 22.12；預先編譯的 bridge 安裝包內含 runtime：

```powershell
npm i -g @agentclientprotocol/claude-agent-acp    # Claude Code
npm i -g @agentclientprotocol/codex-acp           # Codex
npm i -g @deepseek-ai/dsh                        # DeepSeek Harness（原生 ACP）
# Kimi Code 自帶 `kimi acp`
# Hermes Agent 使用 `hermes acp`，安裝方式見下方
# Antigravity 使用官方 ACP server，安裝方式見下方
```

安裝 bridge：

Linux／macOS 一行安裝（預設 nightly）：

```sh
curl -fsSL https://raw.githubusercontent.com/AvianJay/codeaw/master/install.sh | sh
```

安裝器自動選擇 x64／ARM64 與 glibc／musl，下載後驗證 `SHA256SUMS`，將執行檔與 `web/` 安裝到 `${XDG_DATA_HOME:-~/.local/share}/codeaw-bridge`，並在 `~/.local/bin/codeaw-bridge` 建立指令連結。不需 sudo、Node 或 Bun；需要 `curl`、`tar`、`sha256sum` 與一般 Linux 命令列工具。若 `~/.local/bin` 尚未加入 PATH，依安裝完成時的提示設定，再執行 `codeaw-bridge start`，首次啟動會建立設定並顯示配對 QR code。Tailscale 與 ACP agents 仍需另外安裝。

macOS 會選擇 Intel／Apple Silicon 套件並使用內建 `shasum` 驗證；安裝後執行 `codeaw-bridge tray`，選單列提供配對、ACP 安裝、設定、裝置管理與更新。macOS 也可使用 `codeaw-bridge-macos-x64-setup.dmg`／`codeaw-bridge-macos-arm64-setup.dmg`，將 `codeaw.app` 拖到 Applications 後開啟。未公證版本可能需要在「系統設定 → 隱私權與安全性」允許開啟。

可指定穩定版（`latest`）、版本 tag，或安裝路徑：

```sh
curl -fsSL https://raw.githubusercontent.com/AvianJay/codeaw/master/install.sh | sh -s -- --version latest
curl -fsSL https://raw.githubusercontent.com/AvianJay/codeaw/master/install.sh | sh -s -- --version v0.1.0
sh install.sh --install-dir "$HOME/apps/codeaw-bridge" --bin-dir "$HOME/.local/bin"
```

重跑同一指令即可更新，保留 `~/.codeaw` 的設定、配對與歷史；更新後需停止並重新啟動 bridge 程序，服務模式則執行 `codeaw-bridge service restart`。一般 `codeaw-bridge restart` 只重新載入設定，不會載入新的執行檔。要登入自動啟動，可在安裝後執行 `codeaw-bridge service install && codeaw-bridge service start`（需要可用的 systemd user session；詳見下方服務模式）。

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
| `filesystem.allowAllPaths` | 預設 `false`；在電腦上選擇允許瀏覽所有磁碟／資料夾後，手機可從 C:、D: 等磁碟開新對話 |
| `agents.<id>.env` | 額外環境變數，例如給某個 agent 指定不同的 `ANTHROPIC_BASE_URL` |
| `notifications.ntfy` | 推播設定，見下方 |
| `idleSessionCloseMinutes` / `idleAgentStopMinutes` | 閒置多久後釋放 agent 資源（需要時會自動恢復） |

其他指令：`codeaw-bridge pair`（再配對一台裝置）、`codeaw-bridge devices`（列出已配對裝置）、`codeaw-bridge revoke <id>`（撤銷裝置）。

若需瀏覽工作區以外的資料夾，在 Windows 系統匣「設定…」勾選「允許已配對裝置瀏覽所有磁碟與資料夾」，或在 YAML 加入 `filesystem: { allowAllPaths: true }` 後重新載入 bridge。此設定只能從電腦端啟用。**所有已配對裝置都能瀏覽、讀取這個 Windows 帳號可存取的檔案，並在任意資料夾啟動 agent／終端機**，包括私人資料；建議只配對可信任的裝置。不需此功能時取消勾選。資料夾限制不是 agent 或 shell 的安全沙箱，其權限仍由作業系統及 agent 設定決定。不存在的工作目錄會在啟動 agent 前直接回報錯誤。

在新對話的「瀏覽…」選好父目錄後，按右上角的「新增資料夾」圖示，輸入名稱並建立。App 會進入新目錄，按「選這裡」即可用它開新對話；專案檔案頁也有相同按鈕。建立只限目前允許存取的目錄，不會覆蓋同名檔案，也不會自動開啟所有磁碟權限。

聊天輸入列的「附加 → 上傳檔案」可選擇 iOS「檔案」等原生檔案選擇器。一般檔案以已配對裝置的認證上傳至電腦的 `<session cwd>/.codeaw-uploads/`，每個檔案上限 512 MiB，使用唯一名稱避免覆蓋，送出訊息時提供 agent 可讀取的本機路徑。手機與 bridge 分段讀取／寫入，Web 直接傳送瀏覽器 Blob，避免整份大檔案複製到記憶體。持續傳輸可用最長一小時；bridge 在兩分鐘沒有收到資料時終止傳輸並清除未完成檔案。選取後顯示檔名、上傳百分比與已傳／總大小；多檔案依序上傳並顯示目前檔案序號。100% 表示資料已送出，仍需等待電腦確認保存成功才會加入附件並允許送出。檔案保留在電腦供後續回合使用；不用時可自行清除該目錄。上傳或送出失敗會顯示錯誤，已成功的附件與草稿保留供重試。相簿／拍照／剪貼簿圖片及選到的 4 MiB 以下有效圖片仍使用圖片內容傳送。

手機橫向會維持精簡聊天版面；鍵盤只在輸入欄取得焦點時開啟，可點輸入欄外、拖曳聊天列表，或按「收起鍵盤」。切換對話與開啟選擇器會解除舊輸入欄焦點。Windows 互動終端機會將手機的 LF 換行轉為 PowerShell 的 Enter（CR），避免只出現 `>>` 而未執行。

聊天中自己上傳的圖片和 AI 回傳的圖片都可點擊開啟大圖，支援雙指縮放、拖曳、點兩下放大及重設縮放；重新連線後的圖片仍透過已配對 bridge 讀取。

訊息下方一個勾表示 bridge 已收到，兩個勾表示 AI 已開始處理。排隊訊息在真正交給 AI 前保持一個勾；兩個勾不表示 AI 已完成回覆。傳送中或斷線而結果不明會顯示時鐘，請先查看聊天紀錄再重試。已收到的訊息會立即清空輸入欄，斷線、切換對話或回到 App 不會把它填回草稿。

### ACP agent 安裝器

Windows 系統匣與 macOS 選單列都可開啟「安裝 ACP agent…」，也能執行 `codeaw-bridge agents --window`。安裝器從 [ACP registry](https://github.com/agentclientprotocol/registry) 載入可用 agent，顯示版本、平台支援與安裝進度。

所有平台都可使用 CLI：

```powershell
codeaw-bridge agents list
codeaw-bridge agents install claude-acp
codeaw-bridge agents install codex-acp
codeaw-bridge agents install kimi
codeaw-bridge agents install antigravity-acp
codeaw-bridge restart    # bridge 已啟動時，重新啟動以套用安裝；會中止執行中的回合
```

agent 安裝在設定檔旁的 `agents/`（預設 `~/.codeaw/agents/`），不需要管理員權限或修改 PATH。npm agent 需要本機 Node.js 與 npm，Python agent 需要 [uv](https://docs.astral.sh/uv/)；二進位 agent 直接下載符合平台的 ZIP、tar.gz 或執行檔，registry 提供 SHA-256 時會驗證。安裝失敗可重試，原版本與設定保持可用；更新會保留 YAML 註解、agent 環境變數、自訂名稱與啟用狀態。登入、API key 與其他 agent 設定仍沿用本機設定。DeepSeek Harness 目前仍使用上方的 npm 安裝方式；Hermes Agent 目前不在 ACP registry，請依下方指引安裝。

macOS 的 npm 安裝器會先檢查 Node.js／npm；若缺少或損壞，會下載官方 Node 24、驗證 SHA-256，放在設定旁的 `runtime/node/`，不更動 Homebrew 或系統 Node。新設定只列出真正找到的 ACP 執行檔，不再自動加入未安裝的 Claude。

### Hermes Agent

先依照 Hermes 的[官方安裝指引](https://hermes-agent.nousresearch.com/docs/getting-started/installation)安裝，並確認已啟用 [ACP 支援](https://hermes-agent.nousresearch.com/docs/user-guide/features/acp)。在本機執行 `hermes model` 設定 provider 與模型，再以 `hermes acp --check` 檢查 ACP 環境。

bridge 會在建立設定時偵測 PATH 上的 `hermes`，以 `hermes acp` 啟動 Hermes Agent，沿用 Hermes 本機的設定、認證、記憶與 skills。

如果已經有 `~/.codeaw/config.yaml`，在既有的 `agents` 區塊加入以下項目，再執行 `codeaw-bridge restart`：

```yaml
agents:
  hermes:
    name: Hermes Agent
    command: hermes
    args: [acp]
    env: {}
    enabled: true
```

若 `hermes` 不在 bridge 的 PATH 上，將 `command` 改為啟動器的完整路徑；也可改用 `command: hermes-acp` 搭配 `args: []`。

### DeepSeek Harness

bridge 會在建立設定時偵測 PATH 上的 `dsh`，以 [`dsh --profile acp`](https://github.com/deepseek-ai/deepseek-harness/blob/master/apps/cli/README.md) 啟動 DeepSeek Harness。沿用 Harness 本機設定與認證；使用 API key 時，讓 bridge 啟動環境提供 `DEEPSEEK_API_KEY`。

如果已經有 `~/.codeaw/config.yaml`，在既有的 `agents` 區塊加入以下項目，再執行 `codeaw-bridge restart`：

```yaml
agents:
  deepseek:
    name: DeepSeek Harness
    command: dsh
    args: [--profile, acp]
    env: {}
    enabled: true
```

Harness 的 [ACP server](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/acp/acp/README.md) 支援列出、接續與關閉對話，但不回放既有訊息。經 bridge 進行的對話由 bridge 保留歷史；首次接續其他客戶端建立的 Harness 對話時，不會補傳舊訊息。

### Google Antigravity

從 [ACP registry 的官方 Antigravity 項目](https://github.com/agentclientprotocol/registry/blob/main/antigravity-acp/agent.json) 下載符合作業系統與 CPU 架構的 `distribution.binary` 壓縮檔並解壓縮。將解壓縮目錄加入 PATH；macOS／Linux 也需讓 `agy_acp_server.par` 有執行權限（`chmod +x agy_acp_server.par`）。這是獨立的 ACP server，無須安裝 `agy` CLI。

bridge 建立設定時會偵測 Windows 上的 `agy_acp_server.exe`，或 macOS／Linux 上的 `agy_acp_server.par`；Linux 會依 registry 設定傳入 `--uid=`。第一次使用前，先透過官方支援的 ACP 客戶端完成登入，例如 [Zed 的 Antigravity 登入流程](https://antigravity.google/docs/ide/extensions/zed)；之後 bridge 沿用儲存的認證。尚未登入時，建立對話會回報需要認證。

如果已經有 `~/.codeaw/config.yaml`，在既有的 `agents` 區塊加入以下 Windows 設定，再執行 `codeaw-bridge restart`：

```yaml
agents:
  antigravity:
    name: Google Antigravity
    command: agy_acp_server.exe
    args: []
    env: {}
    enabled: true
```

macOS 將 `command` 改成 `agy_acp_server.par`；Linux 另將 `args` 改成 `["--uid="]`。未加入 PATH 時，`command` 可填入執行檔的完整路徑。

### Windows Codex 桌面同步

Windows 上的 `codex` agent 預設啟用桌面同步。先在 ChatGPT desktop app 的 Codex 頁面開啟對話，再從 codeaw 載入同一個 session。bridge 透過桌面 IPC 訂閱該對話，將手機的操作交給原 owner；不會為這條對話再啟動一個 ACP runtime。App 標題列會顯示「桌面同步」。

支援雙向訊息、圖片、串流回覆、命令與檔案變更、桌面發起的回合、插話、手機排隊、停止、工具批准，以及一般問題／MCP 表單回覆。手機斷線時桌面工作繼續；桌面 IPC 斷線後 bridge 會重新尋找 owner 並補齊歷史。發送結果不明的訊息不會自動重送。選擇「停止桌面同步」只解除訂閱並取消尚未發送的手機排隊訊息，桌面正在執行的工作會繼續。

沒有桌面 owner 的對話與從 codeaw 新建的對話，仍使用原有 ACP 模式。已經附加過桌面的 session 會記住這個連接方式：owner 不可用時會提示重新連接，不會悄悄改成另一個 runtime。手機可修改模型、推理強度、權限模式與 Default／Plan 協作模式；變更交由桌面 owner 套用並確認，作用於下一回合，進行中的回合保持原設定。模型清單讀取本機 Codex catalog metadata，也可輸入自訂模型 ID；實際可用性依帳號及桌面版本。刪除對話、特殊選擇器、密碼問題及 URL 授權流程，請在桌面操作。

回合進行中一般「送出」會直接插入目前回合，長按「送出」則排到下一回合。bridge 會提供桌面新版 IPC 所需的訊息還原上下文並檢查接受結果；插入未獲確認會回報錯誤，避免誤稱成功。切換下一回合的模型設定不會中斷插話所在的回合。

桌面 IPC 是內部介面，桌面更新可能需要同步更新 bridge。bridge 會從已安裝 app 的程式包讀取 IPC 方法版本表，不讀取桌面認證檔。可以在 agent 設定中關閉桌面同步，或指定其他 IPC／程式包位置：

```yaml
agents:
  codex:
    name: Codex
    command: codex-acp
    args: []
    env: {}
    enabled: true
    desktopSync: false
    # 或 desktopSync: { pipe: '<IPC pipe>', archivePath: '<app.asar>' }
```

關閉此功能後，已標記為桌面同步的對話需要重新啟用才能開啟。設定變更在重新啟動 bridge 後生效。此版針對 Windows 本機 Codex；Claude Code 仍沿用原有的 ACP 接續方式。

### 系統匣與背景運行

Windows 執行 `codeaw-bridge tray`（或不帶指令）後可以關掉終端機，bridge 會繼續在背景運行。重複啟動會連到同一個 bridge，同一桌面只會有一個系統匣圖示。雙擊圖示開啟 App，右鍵選單提供：

- **開啟 App**：以 Edge 獨立 App 視窗開啟本機 Web App，自動使用一次性配對碼並進入會話列表，無須掃碼或手動輸入。重複開啟會沿用有效的配對；已撤銷時自動重新配對。未安裝 Edge 時使用預設瀏覽器；原始碼開發需先在 `bridge` 執行 `npm run build:web`。啟動後會移除網址中的配對參數。
- **配對手機**：QR code、可複製的網址與配對碼、五分鐘倒數、重新產生配對碼及配對成功提示。也能執行 `codeaw-bridge pair --window`。
- **設定**：連接埠、工作目錄、agent 開關、ACP agent 安裝與閒置時間。保留 YAML 註解及進階欄位；儲存後重啟，若新連接埠無法使用則回復原設定。也能執行 `codeaw-bridge settings`。
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

### Bridge 更新

Windows 系統匣的「Bridge 更新…」可檢查版本、切換 `release`／`nightly` 頻道，並下載更新。也可執行 `codeaw-bridge update --window` 開啟更新視窗。

```powershell
codeaw-bridge update check
codeaw-bridge update check --channel nightly
codeaw-bridge update install     # 已安裝的 Windows 版：驗證後開啟 NSIS 安裝程式
codeaw-bridge update download    # 下載目前平台的可攜版並驗證
```

更新只會在使用者操作後下載或安裝。下載會檢查檔案大小及 SHA-256；nightly 會比較建置編號。頻道選擇保存在設定資料夾，不修改 agent 設定。安裝更新會中止執行中的回合，保留設定與配對裝置；已註冊 Windows 服務時需先移除服務再更新。可攜版、Linux、macOS 或從原始碼執行時，使用 `update download` 取得已驗證的壓縮檔，停止 bridge 後解壓並替換執行檔與 `web/`。下載保存在設定資料夾的 `updates/`，更新完成後可刪除。

CI 發布 `bridge-update.json`，包含各平台安裝包與可攜版的網址、大小及 SHA-256，並將版本、建置編號、頻道與目標平台寫入執行檔。首次發布更新 manifest 前，檢查會提示該頻道尚未提供更新資料。

### Windows 防火牆

如果手機連不上，但電腦自己可以連，請用系統管理員身分允許來自 tailnet 的連線：

```powershell
New-NetFirewallRule -DisplayName "codeaw-bridge (Tailscale)" -Direction Inbound -Protocol TCP -LocalPort 7860 -RemoteAddress 100.64.0.0/10 -Action Allow
```

### 開機自動啟動

Windows／macOS 可從系統匣或選單列勾選「登入後自動啟動」，或使用指令（不需要管理員權限）：

```powershell
codeaw-bridge autostart install
codeaw-bridge autostart status
codeaw-bridge autostart uninstall
```

登入啟動採用使用者的 Windows Run 登錄項目，以隱藏視窗啟動，會沿用本機設定；若 bridge 已由服務啟動，登入時只附加系統匣。舊的 `bridge/scripts/autostart.ps1` 保留為相容入口，也會移除舊版登入排程。

macOS 登入啟動使用 `~/Library/LaunchAgents/tw.codeaw.*.tray.plist`，下次登入後啟動選單列；若 Bridge 已在背景運行，只附加選單列。從 DMG 安裝後，請先把 App 放進 Applications 再啟用，避免啟動路徑指向已卸載的磁碟映像。

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

App「設定 → 更新」選擇 **LCSign** 時會開啟 `loadcontroller://import?url=<percent-encoded HTTPS IPA URL>`，直接讓 LCSign 下載並匯入 IPA，無須先在 Safari 下載再手動分享。此格式已由 [LCSign 官方安裝包](https://www.sign.lc/install) 的 URL scheme 與繁體中文說明確認。匯入後仍需在 LCSign 的「專案／檔案」頁面用原本的憑證與 bundle identifier 簽名並安裝，以保留資料；scheme 不會自動簽名。若未安裝 LCSign 或無法開啟，App 會提供瀏覽器下載備援。

1. 安裝 Tailscale App，並登入同一個 tailnet。
2. 安裝 codeaw App：[nightly release](https://github.com/AvianJay/codeaw/releases/tag/nightly) 的 `codeaw-arm64-v8a.apk` 或 `codeaw-universal.apk`（或用 `cd app && flutter build apk --release --target-platform=android-arm64` 自己建置）。
3. 在電腦上執行 `codeaw-bridge pair`，用 App 的「掃描 QR code」掃終端機上的 QR。也可以手動輸入網址與配對碼；配對碼 5 分鐘內有效，只能用一次。

使用小提示：

- 回合進行中還可以繼續輸入。agent 支援插話（新版 Claude／Codex）時，訊息會直接插進目前的回合；不支援時（Kimi）會排在目前回合之後。長按送出鍵＝一律排隊。
- 對話底部會顯示思考、回覆或工具執行狀態，以及這一輪已處理多久（包含等待批准／回覆的時間）。重新連線後會接續計時，下一輪開始時歸零。
- 輸入框上方的 chip 可以切換模式、模型與推理強度。Claude 的「Manual」模式會在每個危險操作前詢問；`dontAsk` 會直接拒絕沒有預先允許的工具。
- 右上角可以瀏覽專案檔案，或查看 git 變更與 diff。
- 「從電腦重新載入歷史」：如果你在終端機上又繼續聊了同一個 session，用這個重新同步。

### CLI Proxy API 用量

從首頁的用量圖示或「設定 → CPA 用量」開啟「用量與額度」，按「連接 CPA」填入 [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) 的網址與 **Management Key**。這是 CPA 管理金鑰，不是模型呼叫用的 API key。網址可填伺服器根目錄（例如 `http://127.0.0.1:8317`）、`management.html`、反向代理前綴，或明確的 `/v0/management`、`/v8/management`；根目錄預設使用仍受支援的 v0 API。設定與金鑰保存在目前裝置的加密儲存，Web 則使用瀏覽器的加密儲存機制。

由**已配對的 Windows bridge**連到 CPA，因此 `127.0.0.1` 指的是電腦，不是 iPhone；CPA 不必為手機額外開放 CORS。若 CPA 在其他電腦，需允許 bridge 存取其管理 API，依 [CPA 管理 API 文件](https://help.router-for.me/management/api) 設定遠端管理權限，並使用 HTTPS 或可信任的私有網路。Management Key 會經配對連線送到 bridge，再作為認證送到你指定的 CPA；bridge 不將金鑰寫入設定或日誌。

帳號以精簡列表顯示 Codex、Claude、Grok、Antigravity 等類型、方案、剩餘百分比與本地時間的重置倒數。Codex／Claude 可顯示 5 小時、每週及服務商提供的其他視窗；Grok 顯示其每週 credits／每月額度，Antigravity 顯示模型群組。可搜尋、依類型篩選、下拉或逐帳號重新整理。剩餘重置次數只顯示 Codex 回傳的實際可用 reset credits，不以週內時間估算；重置時間已到也需重新整理確認額度。API key 帳號或其他服務商未提供配額時會顯示未知／不支援，不會假設 100%。

用量頁頂部保留各類型的「週／5小時」平均額度，分別計算、不混合 Codex／Claude／AGY。各帳號等權，例如三個 Codex 帳號剩餘 97%、23%、20%，平均顯示 46.7%；未知、失敗、停用或不可用帳號不納入，零額度仍納入。AGY 先平均帳號內相同週期的模型群組，再平均帳號；Codex review 和 Claude 特定模型額度不混入主要額度。搜尋與篩選不改變平均。

設定 CPA 後，聊天標題旁也會顯示目前代理對應的兩條精簡額度條，只標「週／5小時」及一位小數百分比；點擊可查看用量頁。剩餘 ≥50% 為綠色、20–49.9% 為黃色、<20% 為紅色，未知為灰色。手機狹窄版面將部分操作移到選單，保留聊天標題及額度條。App 在前景每 30 秒查詢一次，回到前景或重新連線立即更新；聊天與用量頁共用資料及計時器，正在查詢時不重疊發送，背景暫停。每輪會等全部帳號查詢及平均計算完成後一次更新，期間保留上一輪數值；失敗帳號在完成時標示未知並排除，不逐帳號改動平均額度條。

用量查詢只讀取管理端帳號清單及固定的服務商用量／方案介面，不下載認證檔、不回傳服務商 token、不呼叫模型，也不兌換 reset credits。金鑰可在「CPA 連線設定」移除。App 另提供「設定 → 外觀」的跟隨系統／淺色／深色選擇。

### 推播（App 沒開時）

iOS 16.2+ 另提供「設定 → 即時動態」：鎖定畫面與 Dynamic Island 可顯示聊天標題、專案、執行時間、目前指令及精簡工作摘要，點擊回到該聊天。計時由 iOS 持續顯示；App 暫停後若要繼續更新指令、批准與完成狀態，需要另外設定 Apple APNs 並以具備推播權限的簽名安裝。會追蹤所有執行中的聊天，支援多個即時動態，數量與動態島顯示由 iOS 決定。沒有 APNs 時，保留計時及「上次同步」時間，指令與完成狀態仍須回到 App 才能更新。安裝時必須保留 Widget extension；[詳細設定、限制與測試](docs/live-activities.md)。聊天往上捲動時也會出現「捲到最底」按鈕。

`codeaw-bridge init` 會產生一個隨機的 ntfy topic。在手機安裝 [ntfy](https://ntfy.sh)，然後在 App 的「設定 → 推播通知」點「在 ntfy App 訂閱」。之後當**沒有任何裝置連著**、而 agent 需要批准或已經做完時，就會收到推播，點一下會直接打開那個對話。

推播內容預設只有「Claude Code 需要你的批准／已完成」，不會帶出對話內容（ntfy.sh 是公開的中繼伺服器）。要顯示 session 標題，請設定 `includeDetails: true`，或在 tailnet 內自架 ntfy。

App 在背景但仍保持連線時，則由 App 自己跳本機通知。

### 背景即時進度

Android 在「設定 → 背景進度」開啟後，切到背景時以 Nicko 的常駐進度通知保持 bridge 連線，顯示目前工具／思考／回覆、計畫完成度、聊天標題與已執行時間，點一下回到對話。Android 16 起可成為系統「即時更新」。追蹤切到背景時正在看的對話，或唯一正在執行的對話；回到 App 或排隊工作全部結束時移除。通知與 Android 16 即時更新需在系統設定允許；系統與電池政策仍可能限制背景服務。

iOS 保留多對話 Live Activities：在「設定 → 即時動態」開啟後，動態島與鎖定畫面顯示聊天標題、project、執行時間與最新命令／思考摘要，支援同時追蹤多個執行中的對話（數量受 iOS 限制）。App 回前景／重連會立即刷新。iOS 暫停 App 後需要 bridge 的 APNs 設定與簽章包含相符 push entitlement，才能持續遠端更新；沒有這些條件時會顯示更新已暫停，不能靠長時間保活解決。側載需保留 `CodeawLiveActivity.appex`。詳見 [iOS Live Activities](docs/live-activities.md)。

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

Bridge 會將 `bridge/package.json` 的所有 `bin` 打包成 Windows、Linux（glibc／musl）與 macOS 的 x64／ARM64 執行檔。執行檔內含 runtime，不需另外安裝 Node 或 Bun；Tailscale 與 ACP agents 仍需另外安裝。Windows 提供 NSIS `*-setup.exe` 與可攜式 ZIP；macOS 提供 `*-setup.dmg` 與 tar.gz，Linux 提供 tar.gz，全部列入 `SHA256SUMS`。

Web 先建置，再附入所有 bridge 發行包與 Windows 安裝程式。iOS 在 macOS runner 執行 `flutter build ios --release --no-codesign`，把 `Runner.app` 放進 `Payload/` 壓縮成 `codeaw-ios-unsigned.ipa`，不需要 Apple 簽署 secrets。本機 iOS 建置需 macOS／Xcode，也可以用相同方式打包。

本機已安裝 Bun 1.4.2 或更新版本時，可在 `bridge` 執行 `npm run build:bin`，或用 `npm run build:bin -- --target=bun-linux-arm64` 交叉建置，輸出位於 `bridge/dist/bin`。Windows 執行檔需在 Windows 建置，才能嵌入與 Flutter App 相同的圖示；系統匣和原生視窗會使用這個圖示。本機 Android 建置若未設定 `KEYSTORE_PATH`、`KEYSTORE_ALIAS`、`KEYSTORE_PASSWORD`，會沿用 debug 簽章。

macOS 本機建置另需 Xcode Command Line Tools；先建置 web 與 standalone bridge，再執行 `npm run build:macos -- --out-dir dist/bin` 和 `npm run build:macos-installer`，產生含選單列與 web 的 `bridge/dist/installer/codeaw-bridge-macos-<架構>-setup.dmg`。CI 在對應架構的 macOS runner 建置。

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

輸出為 `bridge/dist/installer/codeaw-bridge-windows-<架構>-setup.exe`；`--bin-dir`、`--out-dir` 可指定輸入與輸出資料夾。Nightly 會在 Windows runner 建置 x64／ARM64 執行檔與安裝包，安裝程式及移除程式也使用相同圖示。

`npm run smoke:installer` 會在 Windows 使用臨時安裝資料夾與獨立 `CODEAW_HOME`，測試靜默安裝、停止執行中的 bridge 後更新、捷徑、登入項目清理與設定保留；若目前帳號已有安裝或捷徑則拒絕覆蓋。CI 也會在 Windows runner 執行此測試，通過後才發布 nightly。

```powershell
cd bridge
npm test                 # vitest：用腳本化的假 agent，不花 token
npm run typecheck
npm run smoke            # 對本機真的 agent 做握手 / 列 session / 開 session（不送 prompt）
npm run smoke:desktop    # Windows：隔離設定渲染三個原生視窗、編譯服務 host；不安裝服務／自動啟動
npm run smoke:tray       # Windows：驗證打包版 CLI 結束後系統匣仍存活，重複啟動只有一個圖示
npm run smoke:macos      # macOS：驗證選單列存活、原生 IPC、重複啟動與重啟／停止（隔離設定）
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
