import AppKit
import SwiftUI

// MARK: - 启动自检日志（排查「菜单栏看不到」这类问题）

enum StatusDiag {
    static var logURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("PulseBar.log")
    }

    static func log(_ text: String) {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm:ss"
        let line = "[\(fmt.string(from: Date()))] \(text)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var eventMonitor: Any?
    private var floating: NSWindow?
    private var floatingObserver: NSObjectProtocol?
    private var floatingSignature = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let env = ProcessInfo.processInfo.environment
        migrateOldDefaultsIfNeeded()

        makeStatusItem()

        if env["STATBAR_NOPOPOVER"] != "1" {
            popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true
            popover.contentViewController = NSHostingController(rootView: PanelView(model: model))
            popover.delegate = self
        }

        if env["STATBAR_NOSAMPLE"] != "1" {
            model.start()
        }
        refreshTitle()

        // 每秒只更新菜单栏文字，指标采样由模型自己的计时器负责
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshTitle()
            self?.syncFloating()
        }

        // 启动 3 秒后自报状态栏项的真实位置，写进 ~/Library/Logs/PulseBar.log
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.reportStatusItem()
        }
    }

    /// 把状态栏项的真实几何信息写进日志，用来判断「被菜单栏挤掉」还是「压根没建出来」
    private func reportStatusItem() {
        guard let button = statusItem.button else {
            StatusDiag.log("❌ 状态栏按钮不存在")
            return
        }
        let win = button.window
        let frame = win?.frame ?? .zero
        let screens = NSScreen.screens.map { s -> String in
            "\(Int(s.frame.width))x\(Int(s.frame.height))@(\(Int(s.frame.minX)),\(Int(s.frame.minY)))"
        }.joined(separator: " , ")
        let mainW = NSScreen.main?.frame.width ?? 0

        var verdict = "未知"
        var visible = false
        if win == nil {
            verdict = "❌ 按钮没有窗口 → 状态栏项未挂载"
        } else if frame.maxX <= 0 || frame.minX >= mainW || frame.minY < 0 || frame.maxY <= 0 {
            verdict = "❌ 窗口在屏幕外 → 被系统隐藏（菜单栏未允许该 App 显示）"
        } else if !(win?.isVisible ?? false) {
            verdict = "⚠️ 窗口存在但不可见"
        } else if overlapsSystemItems(frame) {
            verdict = "❌ 被系统图标盖住 → 未真正显示（菜单栏未允许该 App 显示）"
        } else {
            verdict = "✅ 正常显示"
            visible = true
        }

        StatusDiag.log("状态栏项: \(verdict) | frame=\(frame) | 标题=\"\(button.title)\" | 菜单栏厚度=\(NSStatusBar.system.thickness) | 屏幕=[\(screens)]")

        if visible {
            healAttempts = 0
            return
        }

        // 没显示出来：先自己抢救，再考虑提示用户
        if healAttempts < 2 { attemptHeal() } else { offerMenuBarGuidance() }
    }

    // MARK: - 自我抢救
    //
    // macOS 26 起，第三方菜单栏项可能被系统丢到「溢出槽」里（表现为窗口跑到
    // 系统图标区、被时钟盖住）。实测把 item 重新挂载一次，有机会让它回到正常位置。
    // 注意：autosaveName 保持不变——换名字等于换了身份，反而可能丢掉已获得的显示授权。

    private var healAttempts = 0

    private func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // 稳定标识：系统靠它记住这一项的显示位置与授权状态
        statusItem.autosaveName = "PulseBar"
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        } else {
            StatusDiag.log("❌ statusItem.button 为 nil，状态栏项创建失败")
        }
    }

    private func attemptHeal() {
        healAttempts += 1
        StatusDiag.log("↻ 未显示，尝试重新挂载状态栏项（第 \(healAttempts) 次）")
        statusItem.isVisible = false
        NSStatusBar.system.removeStatusItem(statusItem)
        makeStatusItem()
        refreshTitle()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.reportStatusItem()
        }
    }

    /// 从旧 bundle id 迁移设置，避免换身份后用户设置被清空。
    /// 会按顺序尝试历史上用过的几个 id。
    private func migrateOldDefaultsIfNeeded() {
        let marker = "didMigrateLegacySettings"
        let d = UserDefaults.standard
        guard !d.bool(forKey: marker) else { return }

        let legacyIDs = ["com.micky.statbar", "com.micky.pulsebar"]
        var migrated = false
        for id in legacyIDs where id != Bundle.main.bundleIdentifier {
            guard let old = UserDefaults(suiteName: id) else { continue }
            let skipPrefixes = ["NSNav", "NSWindow", "Apple", "NSToolbar", "AKLast", "com.apple"]
            for (k, v) in old.dictionaryRepresentation()
            where !skipPrefixes.contains(where: { k.hasPrefix($0) }) {
                // 新域里已有值的不要覆盖
                if d.object(forKey: k) == nil { d.set(v, forKey: k) }
            }
            migrated = true
        }
        d.set(true, forKey: marker)
        if migrated { StatusDiag.log("已从旧 bundle id 迁移设置") }
    }

    /// 判断状态栏项是不是被系统图标盖住了。
    ///
    /// 坑点：macOS 26 起，第三方菜单栏项**也由「控制中心」进程渲染**，
    /// 所以按 owner 过滤时会把我们自己也算进"系统图标"，必须先排除自身窗口。
    ///
    /// 判定只用左边界：正常时我们的项排在系统项左侧（有少量右侧重叠是允许的），
    /// 一旦左边界都进了系统区，才是真的被埋住。
    /// 实测：正常 frame.minX=1862（系统项左边界 1948）；被藏起来时 minX=2474。
    private func overlapsSystemItems(_ frame: NSRect) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return false }
        var leftEdge = CGFloat.greatestFiniteMagnitude
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 25 else { continue }
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            guard owner == "控制中心" || owner == "Control Center" else { continue }
            guard let b = w[kCGWindowBounds as String] as? [String: Any],
                  let x = b["X"] as? CGFloat,
                  let ww = b["Width"] as? CGFloat else { continue }
            // 排除自身：与自己的 frame 重合的就是我们自己
            if x <= frame.minX + 1 && x + ww >= frame.maxX - 1 { continue }
            leftEdge = min(leftEdge, x)
        }
        guard leftEdge < .greatestFiniteMagnitude else { return false }
        return frame.minX >= leftEdge - 1
    }

    /// macOS 26 (Tahoe) 起，第三方 App 的菜单栏图标需要在「系统设置 → 菜单栏」里被允许。
    /// 检测到图标真的没显示时主动提示用户，否则用户只会以为软件坏了。
    private func offerMenuBarGuidance() {
        let key = "lastMenuBarGuidanceAt"
        let last = UserDefaults.standard.double(forKey: key)
        if last > 0, Date().timeIntervalSince1970 - last < 24 * 3600 { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "PulseBar 在正常运行，但图标被系统藏起来了"
            alert.informativeText = """
            从 macOS 26 (Tahoe) 开始，第三方软件的菜单栏图标需要在系统里单独允许。

            请打开「系统设置 → 菜单栏」，在下方列表里找到 PulseBar，把开关打开，图标就会立刻出现。

            软件本身没有故障，各项指标都在正常采集。
            """
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "我知道了")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: 悬浮小窗
    //
    // macOS 26 可能不给第三方 App 显示菜单栏图标。这时悬浮窗是唯一能"一直看到温度"的办法。

    private func syncFloating() {
        guard model.settings.showFloating else {
            closeFloatingWindow()
            return
        }
        // 只有"显示项"变化时才重建窗口（宽度随之更新）；平时绝不动它 ——
        // 上一版每帧按内容自适应宽度，导致窗口一直左右跳动。
        let sig = model.settings.menuBarItems.map { $0.rawValue }.joined(separator: ",")
        if floating == nil || sig != floatingSignature {
            closeFloatingWindow()
            showFloatingWindow(signature: sig)
        }
    }

    private func closeFloatingWindow() {
        if let o = floatingObserver {
            NotificationCenter.default.removeObserver(o)
            floatingObserver = nil
        }
        floating?.orderOut(nil)
        floating = nil
    }

    private func showFloatingWindow(signature: String) {
        floatingSignature = signature

        let hosting = NSHostingView(rootView: FloatingView(model: model))
        hosting.layoutSubtreeIfNeeded()
        // 宽度一次算好并向上取整到 8 的倍数，之后不再随文字变化（「81%→80%」这种不会触发）
        let rawWidth = max(150, hosting.fittingSize.width) + 16   // 留余量，字数变多也不裁切
        let size = NSSize(width: ceil(rawWidth / 8) * 8,
                          height: max(40, hosting.fittingSize.height))

        let saved = UserDefaults.standard
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // 默认放右上角（避开菜单栏）
        var origin = NSPoint(x: vf.maxX - size.width - 20, y: vf.maxY - size.height - 12)
        if saved.object(forKey: "floatX") != nil {
            let sx = saved.double(forKey: "floatX"), sy = saved.double(forKey: "floatY")
            // 旧坐标可能来自别的显示器，夹回可见区域，避免窗口"消失"在屏幕外
            origin = NSPoint(
                x: min(max(sx, vf.minX + 4), vf.maxX - size.width - 4),
                y: min(max(sy, vf.minY + 4), vf.maxY - size.height - 4)
            )
        }

        let w = NSWindow(contentRect: NSRect(origin: origin, size: size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = .floating
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.isMovableByWindowBackground = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.contentView = hosting
        w.orderFrontRegardless()
        floating = w

        // 拖到哪就记到哪 —— 上一版只读不写，所以位置永远记不住
        floatingObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: w, queue: .main
        ) { [weak self] _ in
            guard let f = self?.floating else { return }
            UserDefaults.standard.set(Double(f.frame.origin.x), forKey: "floatX")
            UserDefaults.standard.set(Double(f.frame.origin.y), forKey: "floatY")
        }
    }

    @objc private func toggleFloatingMenu() {
        model.settings.showFloating.toggle()
    }

    private func refreshTitle() {
        guard let button = statusItem.button else { return }
        var title = ""
        if model.settings.showIcon { title += "▰ " }
        title += model.menuBarTitle
        let color: NSColor
        switch model.menuBarLevel {
        case .normal: color = NSColor.labelColor
        case .warning: color = NSColor.systemOrange
        case .critical: color = NSColor.systemRed
        }
        // 诊断用：PULSEBAR_BIGTITLE=1 时把字放到很大，便于截图取证
        let size: CGFloat = ProcessInfo.processInfo.environment["PULSEBAR_BIGTITLE"] == "1" ? 34 : 12
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium),
            .foregroundColor: color,
        ])
    }

    @objc private func statusClicked() {
        let isRight = NSApp.currentEvent?.type == .rightMouseUp
        if isRight { showMenu() } else { togglePopover() }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.tick()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "打开面板", action: #selector(openPanel), keyEquivalent: "")
        menu.addItem(withTitle: "立即刷新", action: #selector(refreshNow), keyEquivalent: "r")
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "菜单栏图标没显示？", action: #selector(showGuidance), keyEquivalent: "")
        menu.addItem(withTitle: model.settings.showFloating ? "关闭悬浮窗" : "打开悬浮窗",
                     action: #selector(toggleFloatingMenu), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 PulseBar", action: #selector(quitApp), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }

        if let button = statusItem.button {
            let origin = NSPoint(x: 0, y: button.bounds.height + 4)
            menu.popUp(positioning: nil, at: origin, in: button)
        }
    }

    @objc private func openPanel() { togglePopover() }
    @objc private func showGuidance() {
        UserDefaults.standard.removeObject(forKey: "lastMenuBarGuidanceAt")
        offerMenuBarGuidance()
    }
    @objc private func refreshNow() { model.tick(); refreshTitle() }
    @objc private func openSettings() {
        model.showSettings = true
        if !popover.isShown { togglePopover() }
    }
    @objc private func quitApp() { NSApp.terminate(nil) }
}

extension AppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        model.showSettings = false
    }
}
