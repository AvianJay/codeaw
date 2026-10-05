import AppKit
import Darwin

enum ControlError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

func argument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}

func control(_ socketPath: String, _ request: [String: Any]) throws -> Any {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw ControlError.message("Cannot create bridge connection") }
    defer { close(descriptor) }
    var timeout = timeval(tv_sec: 20, tv_usec: 0)
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var noSignal: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(socketPath.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw ControlError.message("Bridge socket path is too long") }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in buffer.copyBytes(from: bytes) }
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { throw ControlError.message("Bridge is not running") }
    var payload = try JSONSerialization.data(withJSONObject: request)
    payload.append(10)
    try payload.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            guard count > 0 else { throw ControlError.message("Cannot send bridge request") }
            offset += count
        }
    }
    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    while !response.contains(10) {
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        guard count > 0 else { throw ControlError.message("Bridge connection closed or timed out") }
        response.append(contentsOf: buffer.prefix(count))
        guard response.count <= 8 * 1024 * 1024 else { throw ControlError.message("Bridge response is too large") }
    }
    let object = try JSONSerialization.jsonObject(with: response.prefix(while: { $0 != 10 })) as? [String: Any]
    guard object?["ok"] as? Bool == true else { throw ControlError.message(object?["error"] as? String ?? "Bridge request failed") }
    return object?["result"] ?? [:]
}

class MenuDelegate: NSObject, NSApplicationDelegate {
    let socketPath: String
    let readyFile: String
    var statusItem: NSStatusItem!
    var statusLine: NSMenuItem!
    var startupItem: NSMenuItem!
    var window: NSWindow?
    var page = ""
    var polling = false
    var failures = 0
    var catalog: [[String: Any]] = []
    var agentPicker: NSPopUpButton?
    var installButton: NSButton?
    var progressLabel: NSTextField?
    var portField: NSTextField?
    var foldersField: NSTextView?
    var agentChecks: [(String, NSButton)] = []
    var settings: [String: Any] = [:]
    var timer: Timer?

    init(socketPath: String, readyFile: String) { self.socketPath = socketPath; self.readyFile = readyFile }

    func request(_ command: String, _ parameters: [String: Any] = [:], quiet: Bool = false, completion: @escaping (Any) -> Void = { _ in }) {
        var payload = parameters
        payload["command"] = command
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try control(self.socketPath, payload)
                DispatchQueue.main.async { completion(result) }
            } catch {
                DispatchQueue.main.async { if !quiet { self.showError(error.localizedDescription) } }
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.title = ""
        statusItem.button?.image = codeawMenuIcon()
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "codeaw"
        let menu = NSMenu()
        statusLine = NSMenuItem(title: "Bridge 啟動中…", action: nil, keyEquivalent: "")
        menu.addItem(statusLine)
        menu.addItem(.separator())
        addMenu(menu, "開啟 App", #selector(openApp))
        addMenu(menu, "配對手機…", #selector(showPair))
        addMenu(menu, "安裝 ACP agent…", #selector(showAgents))
        addMenu(menu, "設定…", #selector(showSettings))
        addMenu(menu, "已配對裝置…", #selector(showDevices))
        addMenu(menu, "檢查更新…", #selector(showUpdates))
        menu.addItem(.separator())
        startupItem = addMenu(menu, "登入後自動啟動", #selector(toggleStartup))
        addMenu(menu, "重新啟動 Bridge", #selector(restartBridge))
        addMenu(menu, "結束 codeaw", #selector(quitBridge))
        statusItem.menu = menu
        try? Data("ready".utf8).write(to: URL(fileURLWithPath: readyFile), options: .atomic)
        request("autostart", quiet: true) { result in self.startupItem.state = (result as? [String: Any])?["enabled"] as? Bool == true ? .on : .off }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in self.poll() }
        poll()
    }

    @discardableResult func addMenu(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    func poll() {
        guard !polling else { return }
        polling = true
        DispatchQueue.global(qos: .utility).async {
            do {
                let result = try control(self.socketPath, ["command": "poll"]) as? [String: Any] ?? [:]
                DispatchQueue.main.async {
                    self.polling = false
                    self.failures = 0
                    self.statusLine.title = "Bridge \(result["state"] ?? "running") · \(result["clients"] ?? 0) 連線"
                    if let next = result["page"] as? String { self.showPage(next) }
                    if self.page == "agents", self.window?.isVisible == true { self.refreshInstaller() }
                    if self.page == "updates", self.window?.isVisible == true { self.refreshUpdater() }
                }
            } catch {
                DispatchQueue.main.async {
                    self.polling = false
                    self.failures += 1
                    self.statusLine.title = "Bridge 無法連線"
                    if self.failures >= 3 { NSApp.terminate(nil) }
                }
            }
        }
    }

    func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "codeaw"
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func confirm(_ message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "繼續")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    func newWindow(_ title: String, _ page: String, height: CGFloat = 540) -> NSView {
        window?.close()
        let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: height), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        created.title = "codeaw — " + title
        created.isReleasedWhenClosed = false
        created.center()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: height))
        created.contentView = view
        self.window = created
        self.page = page
        created.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return view
    }

    @discardableResult func label(_ view: NSView, _ text: String, _ y: CGFloat, height: CGFloat = 40) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.frame = NSRect(x: 24, y: y, width: 512, height: height)
        field.isSelectable = true
        view.addSubview(field)
        return field
    }

    @discardableResult func button(_ view: NSView, _ title: String, _ action: Selector, _ x: CGFloat, _ y: CGFloat, width: CGFloat = 180) -> NSButton {
        let created = NSButton(title: title, target: self, action: action)
        created.frame = NSRect(x: x, y: y, width: width, height: 32)
        created.bezelStyle = .rounded
        view.addSubview(created)
        return created
    }

    func showPage(_ page: String) {
        switch page {
        case "pair": showPair()
        case "agents": showAgents()
        case "settings": showSettings()
        case "devices": showDevices()
        case "updates": showUpdates()
        default: break
        }
    }

    @objc func openApp() {
        request("app") { result in
            if let value = (result as? [String: Any])?["url"] as? String, let url = URL(string: value) { NSWorkspace.shared.open(url) }
        }
    }

    @objc func showPair() {
        request("pair") { result in
            guard let pair = result as? [String: Any] else { return }
            let view = self.newWindow("配對手機", "pair")
            self.label(view, "使用 codeaw App 掃描 QR code；配對碼有效 5 分鐘，只能使用一次。", 480)
            if let qr = pair["qr"] as? String, let encoded = qr.split(separator: ",").last,
               let data = Data(base64Encoded: String(encoded)), let image = NSImage(data: data) {
                let imageView = NSImageView(frame: NSRect(x: 120, y: 150, width: 320, height: 320))
                imageView.image = image
                view.addSubview(imageView)
            }
            self.label(view, "配對碼：\(pair["code"] ?? "")", 102)
            self.label(view, (pair["urls"] as? [String] ?? []).joined(separator: "\n"), 55)
            self.button(view, "產生新配對碼", #selector(self.showPair), 24, 16)
        }
    }

    @objc func showAgents() {
        let view = newWindow("安裝 ACP agent", "agents", height: 340)
        label(view, "從官方 ACP 目錄安裝；macOS 會在必要時準備獨立 Node.js，不更動系統環境。", 268)
        let picker = NSPopUpButton(frame: NSRect(x: 24, y: 215, width: 512, height: 32))
        picker.target = self
        picker.action = #selector(agentChanged)
        view.addSubview(picker)
        agentPicker = picker
        progressLabel = label(view, "載入 ACP 目錄…", 98, height: 105)
        installButton = button(view, "安裝所選 agent", #selector(installAgent), 24, 28)
        installButton?.isEnabled = false
        button(view, "套用：重新啟動 Bridge", #selector(restartBridge), 242, 28, width: 280)
        request("agentCatalog") { result in
            guard self.page == "agents" else { return }
            self.catalog = result as? [[String: Any]] ?? []
            self.agentPicker?.removeAllItems()
            self.agentPicker?.addItems(withTitles: self.catalog.map { "\($0["name"] ?? "") · \($0["version"] ?? "")" })
            self.agentChanged()
        }
    }

    @objc func agentChanged() {
        guard let index = agentPicker?.indexOfSelectedItem, catalog.indices.contains(index) else { return }
        let agent = catalog[index]
        installButton?.isEnabled = agent["supported"] as? Bool == true
        progressLabel?.stringValue = "\(agent["description"] ?? "")\n\(agent["supported"] as? Bool == true ? "可安裝" : "不支援此 Mac") · \(agent["kind"] ?? "")"
    }

    @objc func installAgent() {
        guard let index = agentPicker?.indexOfSelectedItem, catalog.indices.contains(index), let id = catalog[index]["id"] as? String else { return }
        installButton?.isEnabled = false
        request("installAgent", ["id": id]) { _ in self.refreshInstaller() }
    }

    func refreshInstaller() {
        request("installerStatus", quiet: true) { result in
            guard self.page == "agents", let status = result as? [String: Any], let state = status["state"] as? String, state != "idle" else { return }
            self.progressLabel?.stringValue = status["message"] as? String ?? state
            self.installButton?.isEnabled = state != "installing"
            self.agentPicker?.isEnabled = state != "installing"
        }
    }

    @objc func showSettings() {
        request("settings") { result in
            guard let settings = result as? [String: Any] else { return }
            self.settings = settings
            let view = self.newWindow("設定", "settings", height: 600)
            self.label(view, "連接埠（0 = 自動分配）", 542)
            let port = NSTextField(frame: NSRect(x: 300, y: 550, width: 236, height: 26))
            port.stringValue = "\(settings["port"] ?? 7860)"
            view.addSubview(port)
            self.portField = port
            self.label(view, "工作目錄（每行一個完整路徑）", 490)
            let scroll = NSScrollView(frame: NSRect(x: 24, y: 312, width: 512, height: 176))
            scroll.hasVerticalScroller = true
            let folders = NSTextView(frame: scroll.bounds)
            folders.isRichText = false
            folders.string = (settings["workspaces"] as? [String] ?? []).joined(separator: "\n")
            scroll.documentView = folders
            view.addSubview(scroll)
            self.foldersField = folders
            self.label(view, "啟用 agents（未安裝的 agent 請先從安裝視窗安裝）", 258)
            let agentScroll = NSScrollView(frame: NSRect(x: 24, y: 112, width: 512, height: 146))
            agentScroll.hasVerticalScroller = true
            let agents = settings["agents"] as? [[String: Any]] ?? []
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 490, height: max(146, CGFloat(agents.count * 30))))
            self.agentChecks = []
            for (index, agent) in agents.enumerated() {
                guard let id = agent["id"] as? String else { continue }
                let check = NSButton(checkboxWithTitle: "\(agent["name"] ?? id) (\(id))", target: nil, action: nil)
                check.frame = NSRect(x: 4, y: content.frame.height - CGFloat((index + 1) * 30), width: 476, height: 26)
                check.state = agent["enabled"] as? Bool == true ? .on : .off
                content.addSubview(check)
                self.agentChecks.append((id, check))
            }
            agentScroll.documentView = content
            view.addSubview(agentScroll)
            self.label(view, "儲存會重新啟動 Bridge，正在執行的回合將中止。", 58)
            self.button(view, "安裝 ACP agent…", #selector(self.showAgents), 24, 20)
            self.button(view, "儲存並重新啟動", #selector(self.saveSettings), 336, 20, width: 200)
        }
    }

    @objc func saveSettings() {
        guard let port = Int(portField?.stringValue ?? ""), (0...65535).contains(port) else { showError("請輸入 0–65535 的連接埠"); return }
        guard confirm("套用設定並重新啟動 Bridge？正在執行的回合將中止。") else { return }
        let folders = (foldersField?.string ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let enabled = Dictionary(uniqueKeysWithValues: agentChecks.map { ($0.0, $0.1.state == .on) })
        let values: [String: Any] = ["port": port, "workspaces": folders, "agents": enabled,
            "idleSessionCloseMinutes": settings["idleSessionCloseMinutes"] ?? 30, "idleAgentStopMinutes": settings["idleAgentStopMinutes"] ?? 60]
        request("saveSettings", ["settings": values]) { _ in self.window?.close() }
    }

    @objc func showDevices() {
        request("devices") { result in
            let devices = result as? [[String: Any]] ?? []
            let view = self.newWindow("已配對裝置", "devices")
            self.label(view, "撤銷後，該裝置需要重新配對。", 475)
            let scroll = NSScrollView(frame: NSRect(x: 24, y: 24, width: 512, height: 440))
            scroll.hasVerticalScroller = true
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 490, height: max(440, CGFloat(devices.count * 48))))
            for (index, device) in devices.enumerated() {
                let position = content.frame.height - CGFloat((index + 1) * 48)
                let field = NSTextField(labelWithString: device["name"] as? String ?? device["id"] as? String ?? "Device")
                field.frame = NSRect(x: 0, y: position, width: 350, height: 32)
                content.addSubview(field)
                let revoke = self.button(content, "撤銷", #selector(self.revokeDevice(_:)), 374, position, width: 100)
                revoke.identifier = NSUserInterfaceItemIdentifier(device["id"] as? String ?? "")
            }
            scroll.documentView = content
            view.addSubview(scroll)
        }
    }

    @objc func revokeDevice(_ sender: NSButton) {
        guard confirm("撤銷這個裝置的存取權？"), let id = sender.identifier?.rawValue else { return }
        request("revoke", ["id": id]) { _ in self.showDevices() }
    }

    @objc func showUpdates() {
        let view = newWindow("Bridge 更新", "updates", height: 300)
        label(view, "macOS 更新會下載已驗證的可攜版；停止 Bridge 後替換執行檔與 web 資料夾。", 216)
        progressLabel = label(view, "正在檢查更新…", 88, height: 110)
        button(view, "檢查更新", #selector(checkUpdate), 24, 24)
        button(view, "下載可攜版", #selector(downloadUpdate), 316, 24, width: 220)
        checkUpdate()
    }

    @objc func checkUpdate() { request("checkUpdate") { _ in self.refreshUpdater() } }
    @objc func downloadUpdate() { request("prepareBridgeUpdate", ["kind": "portable"]) { _ in self.refreshUpdater() } }
    func refreshUpdater() {
        request("updaterStatus", quiet: true) { result in
            guard self.page == "updates", let status = result as? [String: Any] else { return }
            self.progressLabel?.stringValue = status["message"] as? String ?? ""
        }
    }

    @objc func toggleStartup() {
        request("setAutostart", ["enabled": startupItem.state != .on]) { result in
            self.startupItem.state = (result as? [String: Any])?["enabled"] as? Bool == true ? .on : .off
        }
    }

    @objc func restartBridge() {
        guard confirm("重新啟動 Bridge？正在執行的回合將中止。") else { return }
        request("restart") { _ in self.poll() }
    }

    @objc func quitBridge() { request("stop") { _ in NSApp.terminate(nil) } }
}

if let preview = argument("--icon-preview") {
    let image = codeawMenuIcon()
    image.isTemplate = false
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 144, pixelsHigh: 144, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(x: 0, y: 0, width: 144, height: 144))
    NSGraphicsContext.restoreGraphicsState()
    do { try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: preview)); exit(0) }
    catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
}
guard let socketPath = argument("--socket") else { fputs("Missing --socket\n", stderr); exit(2) }
if CommandLine.arguments.contains("--check") {
    do { print(try control(socketPath, ["command": "status"])); exit(0) }
    catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
}
guard let readyFile = argument("--ready") else { fputs("Missing --ready\n", stderr); exit(2) }
let lockFile = open(socketPath + ".tray.lock", O_CREAT | O_RDWR, mode_t(0o600))
guard lockFile >= 0 else { fputs("Cannot lock menu bar\n", stderr); exit(1) }
if flock(lockFile, LOCK_EX | LOCK_NB) != 0 {
    try? Data("existing".utf8).write(to: URL(fileURLWithPath: readyFile), options: .atomic)
    exit(0)
}
let app = NSApplication.shared
let delegate = MenuDelegate(socketPath: socketPath, readyFile: readyFile)
app.delegate = delegate
app.run()
