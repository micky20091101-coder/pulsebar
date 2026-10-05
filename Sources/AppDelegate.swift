import AppKit
import SwiftUI
import Combine

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

// MARK: - 面板尺寸测量
//
// 之前面板尺寸完全交给 SwiftUI 的「理想高度」决定，而 ScrollView 的理想高度是无上限的，
// 结果弹窗被撑到满屏（顶天立地）。这里改成：SwiftUI 把真实内容高度报出来，
// AppDelegate 显式设置 popover.contentSize。

final class PanelMetrics {
    /// 当前内容的真实高度（由 PanelView 布局后回填）
    private(set) var contentHeight: CGFloat = 0
    /// 「布局指纹」：只由「布局/宽度/字号/紧凑/显示区块/当前页/是否在设置页」决定。
    /// 实时数据变化（进程数、换页行出现消失…）不会改变它 ——
    /// 这样弹窗只在用户主动切换时调整大小，不会随数据跳动。
    private(set) var signature: String = ""
    /// 指纹变化时的回调（AppDelegate 用它调整弹窗大小）
    var onChange: ((CGFloat) -> Void)?

    func report(_ h: CGFloat, signature sig: String) {
        guard h > 1 else { return }
        contentHeight = h
        guard sig != signature else { return }
        signature = sig
        onChange?(h)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let metrics = PanelMetrics()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var eventMonitor: Any?
    private var floating: NSWindow?
    /// 订阅「菜单栏显示项 / 图标开关」，改一下立刻生效 ——
    /// 否则要等下一次数据刷新（最多 2 秒）才更新，用户会觉得弹窗「莫名其妙过一会儿才跳一下」
    private var settingsBag = Set<AnyCancellable>()
    /// 过渡期间按帧把弹窗钉在图标正下方（系统会先往反方向跑，见 startPinningPanel）
    private var pinTimer: Timer?
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
            popover.contentViewController = NSHostingController(
                rootView: PanelView(model: model, metrics: metrics)
            )
            popover.delegate = self
        }

        if env["STATBAR_NOSAMPLE"] != "1" {
            model.start()
        }
        refreshTitle()

        // 设置一改就立刻重画菜单栏（不用等下一次数据刷新）
        model.settings.$menuBarItems
            .sink { [weak self] _ in self?.refreshTitle() }
            .store(in: &settingsBag)
        model.settings.$showIcon
            .sink { [weak self] _ in self?.refreshTitle() }
            .store(in: &settingsBag)

        // 量到真实内容高度后，同步把弹窗调到合适大小（面板开着的时候）
        metrics.onChange = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.popover.isShown else { return }
                self.applyPopoverSize()
            }
        }

        // 每秒只更新菜单栏文字，指标采样由模型自己的计时器负责
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshTitle()
            self?.syncFloating()
        }

        // 启动 3 秒后自报状态栏项的真实位置，写进 ~/Library/Logs/PulseBar.log
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.reportStatusItem()
        }

        // 诊断用：默认关闭。打开后启动即展开面板，便于截图验证真实尺寸。
        //   defaults write com.micky.pulsebar.mac debugOpenPanel -bool true
        //   defaults write com.micky.pulsebar.mac debugSettings  -bool true   // 直接进设置页
        //   defaults write com.micky.pulsebar.mac debugProbe     -bool true   // 记录窗口抖动
        let d = UserDefaults.standard
        let autoOpen = env["PULSEBAR_OPENPANEL"] == "1" || d.bool(forKey: "debugOpenPanel")
        if autoOpen {
            model.showSettings = d.bool(forKey: "debugSettings")
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.togglePopover()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in
                guard let self = self else { return }
                let size = self.popover.contentSize
                StatusDiag.log("弹窗实测: \(Int(size.width))x\(Int(size.height))，显示中=\(self.popover.isShown)")
            }
        }
        if d.bool(forKey: "debugProbe") { startStabilityProbe() }
    }

    /// 稳定性探针：每 0.5 秒采样一次弹窗窗口的真实位置/尺寸，
    /// 只要变了就记一条日志。用来硬验证「编辑设置时弹窗会不会错位/抖动」。
    private func startStabilityProbe() {
        var last = ""
        var ticks = 0
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            ticks += 1
            if ticks > 240 { t.invalidate(); return }
            guard self.popover.isShown,
                  let win = self.popover.contentViewController?.view.window else { return }
            let f = win.frame
            // 顺带看状态栏项自己有没有移动
            var item = "-"
            if let b = self.statusItem.button, let bw = b.window {
                let r = bw.convertToScreen(b.convert(b.bounds, to: nil))
                item = String(format: "%.0f,%.0f %.0fx%.0f", r.minX, r.minY, r.width, r.height)
            }
            let s = String(format: "%.0f,%.0f %.0fx%.0f", f.minX, f.minY, f.width, f.height)
            if s != last {
                StatusDiag.log("⚠️ 弹窗变化 → \(s)   [状态栏项 \(item)]")
                last = s
            }
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

    /// 状态栏项的固定宽度。
    ///
    /// 为什么必须固定：状态栏项的宽度一变，它的中心点就会横移，
    /// 而弹窗是锚在这个中心点上的 —— 结果就是「弹窗错位」。
    /// 数据每 2 秒刷新一次（79% ↔ 100%、334 KB/s ↔ 2.1 MB/s），宽度一直在变，
    /// 弹窗就会一直抖。所以按「当前勾选的项 + 每项可能出现的最宽文本」算一个固定宽度。
    /// 状态栏项的宽度。按「当前勾选的项 + 每项可能出现的最宽文本」算 ——
    /// 数据刷新时这个值不变，所以图标不会因数值变化而抖动。
    private func fixedStatusItemWidth(fontSize: CGFloat) -> CGFloat {
        let font = NSFont.menuBarFont(ofSize: 0)   // 系统菜单栏的原生字体
        var parts: [String] = []
        if model.settings.showIcon { parts.append("▰") }
        for item in model.settings.menuBarItems { parts.append(item.widestSample) }
        let text = parts.isEmpty ? "PulseBar" : parts.joined(separator: "  ")
        // 只留一点余量：状态栏项自身还有内边距，加太多会显得两侧空荡荡
        return ceil((text as NSString).size(withAttributes: [.font: font]).width) + 4
    }

    private func refreshTitle() {
        guard let button = statusItem.button else { return }

        // 注意：这里**不能**因为面板开着就 return ——
        // 用户点开关时菜单栏必须立刻跟着变（实时预览），否则会觉得「点了没反应」。
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
        // 14pt 与 macOS 菜单栏自身的字号一致；12pt 会显得比旁边的系统图标小一圈
        let size: CGFloat = ProcessInfo.processInfo.environment["PULSEBAR_BIGTITLE"] == "1" ? 34 : 14
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.menuBarFont(ofSize: 0),
            .foregroundColor: color,
        ])
        // ★ 文字必须居中：弹窗的箭头指向「状态栏项的中心」，
        //   只有文字也居中，箭头才会正正好好指在字上，而不是指到旁边的空白。
        button.alignment = .center

        // 宽度始终按「当前勾选项」算 —— 加项、减项都立刻生效，
        // 菜单栏永远如实反映你的选择。
        // （图标宽度一变，系统会重排菜单栏，弹窗会跟着挪一下；箭头由系统保持对准。）
        let targetW = fixedStatusItemWidth(fontSize: size)
        if abs(statusItem.length - targetW) > 0.5 {
            // ★ 必须在改宽度**之前**记下弹窗位置 ——
            //   改完之后系统可能已经把它挪偏了，那时再记就把错的位置当成"原点"。
            let holdX = panelWindow()?.frame.minX
            statusItem.length = targetW
            if let holdX {
                // 立刻同步按回原位：系统常常在这次赋值里就顺手把弹窗挪偏了，
                // 这里马上按回去，避免出现「先闪一下」的那一两帧。
                if let w = panelWindow(), abs(w.frame.minX - holdX) > 0.5 {
                    var f = w.frame
                    f.origin.x = holdX
                    w.setFrame(f, display: true)
                }
                beginPanelTransition(holdX: holdX)
            }
        }
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
            refreshTitle()          // 宽度定好
            // ★ 菜单栏重排是系统异步做的：如果改完宽度立刻 show，
            //   NSPopover 会锚到「旧位置」，箭头就指偏了。
            //   所以等状态栏项位置连续两次采样一致（= 重排完成）再弹。
            showPopoverWhenSettled(attempt: 0, last: nil)
            _ = button
        }
    }

    /// 状态栏项在屏幕上的水平中心
    private func statusIconCenter() -> CGFloat? {
        guard let b = statusItem.button, let bw = b.window else { return nil }
        return bw.convertToScreen(b.convert(b.bounds, to: nil)).midX
    }

    private func panelWindow() -> NSWindow? {
        popover.isShown ? popover.contentViewController?.view.window : nil
    }

    /// 改宽度后的「搬家」过程 —— 全程自己按帧控制，不让系统插手。
    ///
    /// 为什么必须这样：
    ///   1. 系统会先把弹窗**朝反方向**抽一下（实测撤项偏差 −104px）；
    ///   2. 菜单栏重排时，图标自己也会**先弹一下**再落定；
    ///   3. `setFrame(animate:)` 自带的动画会被系统的挪动打断，中途抖一下。
    ///
    /// 所以三个阶段都在同一个 60Hz 定时器里做：
    ///   ① 按住：图标还没停稳之前，钉在原来的 x 不动（抵消系统的反向抽动）
    ///   ② 滑动：图标停稳后，自己插值滑到「新中心 − 半宽」（缓动，约 0.15s）
    ///   ③ 守稳：再钉 0.3s，把系统迟到的小动作按回去
    /// - Parameter holdX: **改宽度之前**弹窗所在的 x。
    ///   必须在改宽度前取好 —— 改完之后系统可能已经把弹窗挪偏了。
    private func beginPanelTransition(holdX: CGFloat) {
        guard panelWindow() != nil else { return }
        let startCenter = statusIconCenter() ?? 0
        var phase = 0                 // 0=按住 1=滑动 2=守稳
        var lastCenter: CGFloat?
        var moved = false
        var slideFrom: CGFloat = holdX
        var slideProgress = 0
        var settleTicks = 0

        pinTimer?.invalidate()
        pinTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            guard let self, let w = self.panelWindow() else { t.invalidate(); return }
            guard let center = self.statusIconCenter() else { t.invalidate(); return }
            let target = center - w.frame.width / 2       // 每一帧都按最新中心算，保证最终对齐
            var f = w.frame

            switch phase {
            case 0:
                // ① 按住：图标还没停稳之前，钉在原来的位置，抵消系统的反向抽动
                if abs(center - startCenter) > 1 { moved = true }
                let settled = moved && (lastCenter.map { abs(center - $0) < 0.5 } ?? false)
                if settled || (moved == false && settleTicks > 45) {
                    // 起点必须用 holdX（我们一直按住的位置），
                    // 不能用当前 frame —— 系统可能刚好在这一帧把弹窗挪偏了。
                    slideFrom = holdX
                    slideProgress = 0
                    if abs(f.minX - holdX) > 0.5 { f.origin.x = holdX; w.setFrame(f, display: true) }
                    phase = 1
                    return
                }
                if abs(f.minX - holdX) > 0.5 { f.origin.x = holdX; w.setFrame(f, display: true) }
                lastCenter = center
                settleTicks += 1

            case 1:
                // ② 滑动：自己插值，约 0.15s 缓动滑到新位置
                slideProgress += 1
                let p = min(1.0, Double(slideProgress) / 9.0)
                let eased = 1 - pow(1 - p, 3)
                f.origin.x = slideFrom + (target - slideFrom) * CGFloat(eased)
                w.setFrame(f, display: true)
                if p >= 1.0 { phase = 2; settleTicks = 0 }

            default:
                // ③ 守稳：再钉 0.4s，把系统迟到的小动作按回去
                if abs(f.minX - target) > 0.5 { f.origin.x = target; w.setFrame(f, display: true) }
                settleTicks += 1
                if settleTicks > 24 {
                    t.invalidate()
                    self.pinTimer = nil
                    self.logAlignment()
                }
            }
        }
    }

    /// 把弹窗直接摆到「图标中心 − 半宽」（不做动画，用于落点校正）
    private func pinPanelOnce() {
        guard let win = panelWindow(), let center = statusIconCenter() else { return }
        var f = win.frame
        let desired = center - f.width / 2
        guard abs(f.minX - desired) > 0.5 else { return }
        f.origin.x = desired
        win.setFrame(f, display: true)
    }

    private func logAlignment() {
        guard let b = statusItem.button, let bw = b.window,
              let win = popover.contentViewController?.view.window else { return }
        let iconCenter = bw.convertToScreen(b.convert(b.bounds, to: nil)).midX
        let arrow = win.frame.minX + win.frame.width / 2
        StatusDiag.log(String(format: "面板对齐: 图标中心=%.0f 箭头=%.0f 偏差=%+.0f",
                              iconCenter, arrow, arrow - iconCenter))
    }

    private func showPopoverWhenSettled(attempt: Int, last: CGFloat?) {
        guard !popover.isShown, let b = statusItem.button, let bw = b.window else { return }
        let midX = bw.convertToScreen(b.convert(b.bounds, to: nil)).midX

        let settled = last.map { abs(midX - $0) < 0.5 } ?? false
        guard settled || attempt >= 12 else {          // 最多等 ~0.24s
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                self?.showPopoverWhenSettled(attempt: attempt + 1, last: midX)
            }
            return
        }

        applyPopoverSize()
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        // 首次打开时内容还没布局（量到 0），稍后再修正一次尺寸
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.applyPopoverSize()
        }
    }

    /// 显式设置弹窗大小。
    ///
    /// 关键结论（踩了很久才发现）：
    ///   NSPopover 用的是 `contentSize`，**不是** SwiftUI 内容的 fitting 高度。
    ///   不设的话就是默认的 320x320（面板会很小、要滚动）。
    ///   而且这个值必须等于「整个面板（含头尾）的总高度」，
    ///   只算中间内容区会导致弹窗定位错乱（顶部被切出屏幕）。
    ///   所以 PanelView 会把整面板高度报给 metrics。
    private func applyPopoverSize() {
        let w = CGFloat(model.settings.panelWidth)
        let maxH = (NSScreen.main?.visibleFrame.height ?? 900) - 140
        // contentHeight 是「中间内容区」的高度；面板还有头/尾/内外边距，
        // 这部分实测恒为 87pt（字号变了会等比变化），加回去才是整个面板的高度。
        let chrome = 87 * CGFloat(model.settings.fontScale)
        let content = max(metrics.contentHeight, 300)

        let h: CGFloat
        if model.showSettings {
            // 设置页：高度由 PanelView 锁死（编辑时绝不 resize），这里只用完整高度
            h = content + chrome
        } else {
            // 主面板：只给约六成，滚一点点就能到底
            h = min(content * 0.6, maxH - chrome) + chrome
        }
        let target = NSSize(width: w, height: min(max(h, 360), maxH))

        let cur = popover.contentSize
        guard abs(cur.width - target.width) > 0.5 || abs(cur.height - target.height) > 0.5 else { return }
        // 直接改，不加动画。
        // 试过 NSAnimationContext 过渡，但 NSPopover 在动画期间会重算锚点，
        // 出现「弹窗闪到屏幕角落」的严重错位，所以果断去掉。
        popover.contentSize = target
        StatusDiag.log("面板尺寸 → \(Int(target.width))x\(Int(target.height))（实测 \(Int(metrics.contentHeight))）")
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
        refreshTitle()
        model.showSettings = false
    }
}
