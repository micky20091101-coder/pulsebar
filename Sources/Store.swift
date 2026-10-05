import Foundation
import SwiftUI
import AppKit
import UserNotifications

// MARK: - 菜单栏显示项

enum MenuBarItem: String, CaseIterable, Identifiable {
    case mem, temp, cpu, net, disk, battery
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mem: return "内存"
        case .temp: return "温度"
        case .cpu: return "CPU"
        case .net: return "网络"
        case .disk: return "磁盘"
        case .battery: return "电池"
        }
    }
}

// MARK: - 面板显示区块

enum PanelSection: String, CaseIterable, Identifiable {
    case memory, advice, temperature, fan, cpu, summary, processes
    var id: String { rawValue }
    var title: String {
        switch self {
        case .memory:      return "内存压力"
        case .advice:      return "诊断建议"
        case .temperature: return "温度"
        case .fan:         return "风扇转速"
        case .cpu:         return "CPU"
        case .summary:     return "系统概览"
        case .processes:   return "内存占用排行"
        }
    }
}

// MARK: - 清理模式

enum CleanupMode: String, CaseIterable, Identifiable {
    case manual, notify, auto
    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: return "手动"
        case .notify: return "提醒"
        case .auto:   return "自动"
        }
    }

    var detail: String {
        switch self {
        case .manual:
            return "只在面板里显示数据，不发通知、不动任何进程。最安静。"
        case .notify:
            return "内存真的紧张时发一条通知，告诉你是谁在占内存——关不关由你决定。"
        case .auto:
            return "内存严重紧张时，自动结束「后台进程」（不含你正在用的 App、不含保护名单）。有冷却时间，不会反复动手。"
        }
    }

    var icon: String {
        switch self {
        case .manual: return "hand.raised"
        case .notify: return "bell"
        case .auto:   return "wand.and.stars"
        }
    }
}

// MARK: - 设置

final class Settings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var interval: Double { didSet { d.set(interval, forKey: "interval") } }
    @Published var menuBarItems: [MenuBarItem] { didSet { d.set(menuBarItems.map { $0.rawValue }, forKey: "menuBarItems") } }
    @Published var showIcon: Bool { didSet { d.set(showIcon, forKey: "showIcon") } }
    /// 悬浮小窗：菜单栏图标被系统藏起来时的备选方案
    @Published var showFloating: Bool { didSet { d.set(showFloating, forKey: "showFloating") } }
    @Published var cleanupMode: CleanupMode {
        didSet {
            d.set(cleanupMode.rawValue, forKey: "cleanupMode")
            // 通知权限改为「用到才申请」：不在启动瞬间弹权限框，免得惊到用户
            if cleanupMode != .manual { Notifier.requestPermission() }
        }
    }
    @Published var launchAtLogin: Bool { didSet { d.set(launchAtLogin, forKey: "launchAtLogin"); LaunchAtLogin.apply(launchAtLogin) } }
    /// 用户额外保护的进程名（小写）
    @Published var extraProtected: [String] { didSet { d.set(extraProtected, forKey: "extraProtected") } }

    // MARK: 面板显示（解决「必须滚动才能看全」）

    /// 面板宽度：越宽越不容易换行，整体越矮
    @Published var panelWidth: Double { didSet { d.set(panelWidth, forKey: "panelWidth") } }
    /// 字号缩放：0.85 紧凑 / 1.0 标准 / 1.15 宽松
    @Published var fontScale: Double { didSet { d.set(fontScale, forKey: "fontScale") } }
    /// 紧凑间距：卡片内外间距都收紧
    @Published var compactPanel: Bool { didSet { d.set(compactPanel, forKey: "compactPanel") } }
    /// 自动撑开高度：尽量一屏显示完，不用滚动
    @Published var autoFitPanel: Bool { didSet { d.set(autoFitPanel, forKey: "autoFitPanel") } }
    /// 面板里显示哪些区块
    @Published var panelSections: [PanelSection] {
        didSet { d.set(panelSections.map { $0.rawValue }, forKey: "panelSections") }
    }

    init() {
        interval = d.object(forKey: "interval") as? Double ?? 2
        showIcon = d.object(forKey: "showIcon") as? Bool ?? true
        showFloating = d.object(forKey: "showFloating") as? Bool ?? false
        launchAtLogin = d.object(forKey: "launchAtLogin") as? Bool ?? LaunchAtLogin.isEnabled
        extraProtected = d.stringArray(forKey: "extraProtected") ?? []
        cleanupMode = CleanupMode(rawValue: d.string(forKey: "cleanupMode") ?? "") ?? .manual
        let raw = d.stringArray(forKey: "menuBarItems") ?? ["mem", "temp"]
        menuBarItems = raw.compactMap { MenuBarItem(rawValue: $0) }

        panelWidth = d.object(forKey: "panelWidth") as? Double ?? 380
        fontScale = d.object(forKey: "fontScale") as? Double ?? 1.0
        // 默认开启两件「让人少滚动」的事
        compactPanel = d.object(forKey: "compactPanel") as? Bool ?? false
        autoFitPanel = d.object(forKey: "autoFitPanel") as? Bool ?? true
        let secs = d.stringArray(forKey: "panelSections") ?? PanelSection.allCases.map { $0.rawValue }
        panelSections = secs.compactMap { PanelSection(rawValue: $0) }
    }
}

// MARK: - 开机自启

enum LaunchAtLogin {
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.micky.pulsebar.launch.plist")
    }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    static func apply(_ on: Bool) {
        let fm = FileManager.default
        if on {
            let exe = Bundle.main.executablePath ?? "/Applications/PulseBar.app/Contents/MacOS/PulseBar"
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key><string>com.micky.pulsebar.launch</string>
                <key>ProgramArguments</key>
                <array><string>\(exe)</string></array>
                <key>RunAtLoad</key><true/>
                <key>KeepAlive</key><false/>
                <key>ProcessType</key><string>Interactive</string>
            </dict>
            </plist>
            """
            try? fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? plist.write(to: plistURL, atomically: true, encoding: .utf8)
        } else {
            try? fm.removeItem(at: plistURL)
        }
    }
}

// MARK: - 应用主模型

final class AppModel: ObservableObject {
    @Published var snapshot = SystemSnapshot()
    @Published var processes: [ProcInfo] = []
    @Published var settings = Settings()
    @Published var lastActionMessage: String?
    @Published var busy = false
    @Published var showSettings = false

    private let metrics = MetricsSampler()
    private let procSampler = ProcessSampler()
    private var timer: Timer?
    private var hardware: HardwareInfo

    private var lastNotice = Date.distantPast
    private var lastAutoClean = Date.distantPast
    private static let autoCleanCooldown: TimeInterval = 600   // 自动模式冷却 10 分钟
    private static let autoCleanMaxPerRun = 2                  // 一次最多清 2 个

    init() {
        hardware = Hardware.load()
    }

    var hardwareInfo: HardwareInfo { hardware }

    /// 供演示模式替换机型信息
    func setHardware(_ h: HardwareInfo) { hardware = h }

    /// 自适应阈值：一台机器上算「大户」的基准随总内存变化
    /// 8GB → 400MB 起算；32GB → 512MB；64GB 及以上 → 1GB
    var heavyProcessThreshold: Int64 {
        max(400 * 1024 * 1024, hardware.totalMemory / 64)
    }

    func start() {
        tick()
        reschedule()
    }

    func reschedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: settings.interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func tick() {
        snapshot = metrics.sample()
        processes = procSampler.sample(limit: 14,
                                       coreCount: hardware.cpuCount,
                                       extraProtected: Set(settings.extraProtected))
        evaluatePressure()
    }

    // MARK: 压力评估：手动=不打扰 / 提醒=发通知 / 自动=清后台

    private var isPressureCritical: Bool {
        let m = snapshot.memory
        if m.pressureLevel == 4 { return true }
        if m.ratio > 0.90 && m.pageOutsPerSec > 300 { return true }
        if m.swapUsed > 0 && m.pageOutsPerSec > 500 { return true }
        return false
    }

    private var isPressureElevated: Bool {
        let m = snapshot.memory
        return m.pressureLevel >= 2 || m.ratio > 0.85
    }

    private func evaluatePressure() {
        switch settings.cleanupMode {
        case .manual:
            return

        case .notify:
            guard isPressureCritical || isPressureElevated else { return }
            guard Date().timeIntervalSince(lastNotice) > 300 else { return }
            lastNotice = Date()
            let m = snapshot.memory
            if let top = autoCandidates.first {
                Notifier.post(title: isPressureCritical ? "内存紧张：建议关掉「\(top.name)」" : "内存压力偏高",
                              body: "已用 \(Fmt.bytes(m.used)) / \(Fmt.bytes(m.total))，\(top.name) 占 \(Fmt.bytes(top.memory))。关不关你决定。")
            } else {
                Notifier.post(title: "内存压力偏高",
                              body: "已用 \(Fmt.bytes(m.used)) / \(Fmt.bytes(m.total))，暂时没有可安全结束的后台进程。")
            }

        case .auto:
            guard isPressureCritical else { return }
            guard Date().timeIntervalSince(lastAutoClean) > Self.autoCleanCooldown else { return }
            let victims = Array(autoCandidates.prefix(Self.autoCleanMaxPerRun))
            guard !victims.isEmpty else { return }
            lastAutoClean = Date()
            var freed: Int64 = 0
            var names: [String] = []
            for p in victims {
                if terminate(pid: p.id, expecting: p.name) {
                    freed += p.memory
                    names.append(p.name)
                }
            }
            if !names.isEmpty {
                lastActionMessage = "自动清理：结束了 \(names.joined(separator: "、"))，约释放 \(Fmt.bytes(freed))。"
                Notifier.post(title: "已自动清理后台进程",
                              body: "结束了 \(names.joined(separator: "、"))，约释放 \(Fmt.bytes(freed))。你正在用的 App 和保护名单都没动。")
                tick()
            }
        }
    }

    /// 自动清理的候选：非保护、非用户 App、非前台、且达到本机「大户」阈值
    var autoCandidates: [ProcInfo] {
        processes.filter {
            $0.isAutoCleanEligible
                && $0.id != getpid()
                && $0.memory >= heavyProcessThreshold
        }
    }

    // MARK: 菜单栏标题

    var menuBarTitle: String {
        var parts: [String] = []
        for item in settings.menuBarItems {
            switch item {
            case .mem: parts.append(Fmt.percent(snapshot.memory.ratio * 100))
            case .temp: parts.append(Fmt.temp(snapshot.temperature.cpu))
            case .cpu: parts.append("C" + Fmt.percent(snapshot.cpu.usage * 100))
            case .net:
                let n = snapshot.network
                let arrow = n.downPerSec >= n.upPerSec ? "↓" : "↑"
                parts.append(arrow + Fmt.rate(max(n.downPerSec, n.upPerSec)))
            case .disk: parts.append(Fmt.percent(snapshot.disk.ratio * 100))
            case .battery: parts.append(snapshot.battery.present ? Fmt.percent(Double(snapshot.battery.percentage)) : "--")
            }
        }
        return parts.isEmpty ? "PulseBar" : parts.joined(separator: "  ")
    }

    var menuBarLevel: Level {
        var worst = Level.normal
        if settings.menuBarItems.contains(.mem) {
            let l = snapshot.memory.pressureLevelEnum
            if l == .critical { worst = .critical } else if l == .warning && worst != .critical { worst = .warning }
        }
        if settings.menuBarItems.contains(.temp) {
            let l = Level.ofTemp(snapshot.temperature.cpu)
            if l == .critical { worst = .critical } else if l == .warning && worst != .critical { worst = .warning }
        }
        return worst
    }

    // MARK: 内存建议（人性化核心：说清事实，把决定权留给用户）

    struct Advice {
        var level: Level
        var headline: String
        var detail: String
        var candidates: [ProcInfo]
        var potentialFree: Int64
    }

    var advice: Advice {
        let mem = snapshot.memory
        let candidates = processes.filter { !$0.isProtected && $0.id != getpid() }
        let potential = candidates.prefix(5).reduce(0) { $0 + $1.memory }

        if mem.swapUsed > 0 && mem.pageOutsPerSec > 200 {
            return Advice(level: .critical, headline: "正在用交换区，卡顿多半来自这里",
                          detail: "换出速度 \(Fmt.one(mem.pageOutsPerSec)) 页/秒，说明内存确实不够用了。关掉下面几个大户最有效。",
                          candidates: candidates, potentialFree: potential)
        }
        if mem.pressureLevel >= 2 || mem.ratio > 0.85 {
            return Advice(level: .warning, headline: "内存有点紧，但还撑得住",
                          detail: "已用 \(Fmt.bytes(mem.used)) / \(Fmt.bytes(mem.total))。可以先不动，真觉得卡再关下面的。",
                          candidates: candidates, potentialFree: potential)
        }
        return Advice(level: .normal, headline: "内存健康",
                      detail: "压力正常，无需清理。macOS 会自己管理内存，别被「内存占用高」吓到。",
                      candidates: [], potentialFree: 0)
    }

    // MARK: 手动结束进程（一定先确认）

    /// 结束进程。传入 expecting 会先核对进程名，避免 pid 被复用后误杀别的程序。
    @discardableResult
    func terminate(pid: Int32, expecting name: String? = nil) -> Bool {
        guard pid > 0, pid != getpid() else { return false }
        if let name, !name.isEmpty {
            var buf = [UInt8](repeating: 0, count: 256)
            let n = buf.withUnsafeMutableBytes { proc_name(pid, $0.baseAddress, 256) }
            let current = n > 0 ? String(cString: buf) : ""
            // pid 已经属于别的进程了就放弃，绝不误伤
            if !current.isEmpty && current != name { return false }
        }
        return kill(pid, SIGTERM) == 0
    }

    // MARK: 释放可回收内存（purge）—— 如实告知，不做魔法

    func purgeMemory(completion: @escaping (String) -> Void) {
        busy = true
        let before = snapshot.memory.used
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = Self.runPurge()
            let sampled = self?.metrics.sample().memory.used ?? before
            let freed = max(0, before - sampled)
            DispatchQueue.main.async {
                self?.busy = false
                let msg: String
                switch outcome {
                case .success:
                    msg = freed > 0
                        ? "已释放约 \(Fmt.bytes(freed)) 可回收内存。"
                        : "执行完成，但这次没释放出多少——说明内存大多在被真实占用（而不是缓存）。"
                case .cancelled:
                    msg = "已取消（未输入管理员密码）。"
                case .failure(let e):
                    msg = "没能执行：\(e)"
                }
                self?.lastActionMessage = msg
                completion(msg)
            }
        }
    }

    private enum PurgeResult { case success, cancelled, failure(String) }

    private static func runPurge() -> PurgeResult {
        if let r = run("/usr/bin/sudo", ["-n", "/usr/sbin/purge"]), r.status == 0 {
            return .success
        }
        let script = "do shell script \"/usr/sbin/purge\" with administrator privileges"
        guard let r = run("/usr/bin/osascript", ["-e", script]) else {
            return .failure("无法调用系统授权")
        }
        if r.status == 0 { return .success }
        if r.err.contains("-128") || r.err.contains("User canceled") { return .cancelled }
        return .failure(r.err.isEmpty ? "退出码 \(r.status)" : r.err)
    }

    @discardableResult
    private static func run(_ launchPath: String, _ args: [String]) -> (status: Int32, out: String, err: String)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, out, err)
    }

    func quit() { NSApp.terminate(nil) }
}

// MARK: - 通知

enum Notifier {
    /// 裸二进制（不在 .app bundle 内）调用通知中心会抛异常，这里先兜底
    private static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    static func post(title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
