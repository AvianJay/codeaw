# 遠端桌面

操作端支援 Android、iOS 與 Web；電腦端支援 Windows 10／11 x64、ARM64。
使用目前的 Tailscale、配對裝置與連線網址。桌面連線獨立於聊天 ACP，離開桌面頁或 App 進入背景會停止傳圖並釋放按鍵。

## 電腦端啟用

在系統匣「設定」勾選「允許已配對裝置操作遠端桌面」，儲存後重新啟動 bridge。
也可執行：

```powershell
codeaw-bridge remote-desktop enable
codeaw-bridge remote-desktop disable
```

預設關閉；啟用後，已配對裝置可直接連線。同時只有一個控制連線，其他裝置會顯示使用中。
一般權限適用於已登入桌面；高權限視窗或安全桌面可能無法接受輸入。

## 進階權限與登入前連線

系統匣設定提供「安裝進階桌面服務」，由 Windows 顯示管理員授權提示。
需使用含 Web 資產與原生桌面元件的 Windows release，並設定固定連接埠。

```powershell
codeaw-bridge remote-desktop install
codeaw-bridge remote-desktop status
codeaw-bridge remote-desktop uninstall
```

服務開機啟動；Tailscale 就緒後，即使尚未有人登入，也能從原本網址開啟 Web／桌面。
在操作端選擇「進階權限」可控制登入、解鎖與 UAC。登入 Windows 後，使用者 bridge 透過私人管線接上 gateway；agent 仍以原本的使用者帳號執行。

服務與 gateway 安裝於受保護的 Program Files，設定位於 ProgramData。裝置 token 沿用既有配對，只讀取 token 的雜湊登錄。
安裝會啟用此帳號的登入時 bridge 自動啟動；升級可再次執行 install，失敗會回復原服務與設定。
disable 會同時停用已安裝的進階桌面存取；enable 可重新啟用。解除服務後恢復使用者 bridge 的原本 HTTP 入口。

Ctrl+Alt+Del 使用 Windows SendSAS，須由 Windows 安全政策允許服務產生 SAS；安裝不會覆寫網域政策。被禁止時會顯示原因，連線仍可繼續使用。
Windows Hello／其他登入方式由 Windows 決定，Codeaw 不保存登入密碼或 PIN。

## 畫面模式

| 模式 | 解析度上限 | 更新 | 影像預算 |
|---|---|---|---|
| 一般 | 長邊 1600 px | 最多 15 fps，JPEG 局部更新 | 2 Mbps |
| 高流暢 | 1920 × 1080（保留比例） | H.264，30／60 fps | 平均 4 Mbps，最高 8 Mbps |
| 低流量 | 長邊 960 px | 最多 2 fps，JPEG 局部更新 | 128 kbps |
| 極省流量 | 長邊 960 px | 初次、手動刷新、操作後兩秒內最多 1 fps | 64 kbps |

沒有畫面變化就不傳影像。JPEG 預算允許初始畫面突發，較大的單幀會扣抵之後的預算；控制事件、游標、心跳及網路封包開銷不包含在表中。
高流暢優先使用硬體編碼；硬體處理失敗改用軟體 30 fps。WebRTC 八秒內無法顯示畫面時改用一般模式，並顯示原因。
WebRTC 沿 Tailscale 傳輸，不使用公開 STUN／TURN。

首次模式跟隨聊天的「節省數據」：開啟時預設低流量，否則預設一般。之後記住此配對電腦的模式、螢幕、FPS 與權限選擇。
圖片、輸入及 SDP 不寫入聊天歷史、快取或日誌。本次用量與画面留在連線記憶體。

## 操作

手機預設觸控板：滑動移動游標、輕點單擊、按住後拖曳；工具列可切換直接觸控。
可縮放畫面、切換螢幕、開啟鍵盤及使用快捷鍵。中文在本機組字完成後傳送 Unicode。
瀏覽器保留的快捷鍵可從畫面下方快捷鍵列送出。
極省流量中非同步更新的結果需按「刷新畫面」。

第一版鏡像目前實體 console 的單一選定螢幕；音訊、剪貼簿同步、桌面檔案傳輸與多使用者並行工作階段未納入。

## 開發與驗證

```powershell
cd bridge
npm run build:desktop
npm run build
npm run smoke:remote-desktop
npx playwright install chromium
npm run smoke:remote-desktop-webrtc
npm run build:web
npm run build:bin -- --target=bun-windows-x64
```

原生 helper 使用 MSVC、Windows SDK 與 CMake。缺少 CMake 時，建置腳本下載經 SHA-256 驗證的便攜版；原生建置快取預設位於系統暫存目錄，可用 CODEAW_NATIVE_BUILD_DIR 覆寫。
ARM64 建置需要 Visual Studio 的 ARM64 C++ 工具。
WebRTC smoke 使用獨立 headless 瀏覽器及產生的測試像素，驗證 H.264 解碼與 30／60 fps；不讀取使用者視窗或注入輸入。
另需在具管理員權限的 Windows 測試機驗證開機、登入、鎖定、UAC、服務升級及解除安裝。
