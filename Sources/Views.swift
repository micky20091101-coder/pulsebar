import SwiftUI

// MARK: - 字号缩放
//
// 面板里 60 处字号都写成 FS(n) 而不是直接写数字，这样「字号缩放」设置一处生效。
// PanelView 在构建子视图之前先把 factor 设好（body 是从上往下求值的），
// FloatingView 会把它重置回 1.0，免得影响那个独立小窗。
enum UIScale {
    static var factor: CGFloat = 1.0
}

func FS(_ size: CGFloat) -> CGFloat {
    // 夹一层保护：万一设置里存了脏数据，也不会把界面缩成看不见
    // （不用项目里的 clamped，它定义在 Double 上，且和 SwiftUI 新增的 clamped(to:) 重名）
    let f = min(max(UIScale.factor, 0.7), 1.6)
    return max(7, size * f)
}

// MARK: - 紧凑模式（通过环境传递，Card 自己读取）

private struct CompactPanelKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var compactPanel: Bool {
        get { self[CompactPanelKey.self] }
        set { self[CompactPanelKey.self] = newValue }
    }
}

/// 用来把内容真实高度往上传，供面板决定「要不要滚动」
struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - 复用组件

struct Card<Content: View>: View {
    var title: String? = nil
    @Environment(\.compactPanel) private var compact
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 8) {
            if let title {
                Text(title)
                    .font(.system(size: FS(11), weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .textCase(.uppercase)
                    .tracking(0.4)
            }
            content
        }
        .padding(compact ? 9 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.cardStroke, lineWidth: 1))
    }
}

struct Bar: View {
    var ratio: Double
    var level: Level
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(level.color)
                    .frame(width: max(height, geo.size.width * ratio.clamped(0, 1)))
            }
        }
        .frame(height: height)
    }
}

struct MetricLine: View {
    var label: String
    var value: String
    var color: Color = .primary
    var monoValue = true

    var body: some View {
        HStack {
            Text(label).font(.system(size: FS(12))).foregroundStyle(Theme.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: FS(12), weight: .medium, design: monoValue ? .monospaced : .default))
                .foregroundStyle(color)
        }
    }
}

struct Pill: View {
    var text: String
    var color: Color

    var body: some View {
        Text(text)
            .font(.system(size: FS(10), weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

// MARK: - 悬浮小窗（菜单栏图标被系统藏起来时的备选）

struct FloatingView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        // 悬浮小窗不跟随面板的字号缩放，保持它自己的紧凑尺寸
        let _ = { UIScale.factor = 1.0 }()

        return HStack(spacing: 9) {
            Circle()
                .fill(model.menuBarLevel.color)
                .frame(width: 8, height: 8)
            Text(model.menuBarTitle)
                .font(.system(size: FS(13), weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
            Button {
                model.settings.showFloating = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: FS(8), weight: .bold))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭悬浮窗")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Theme.cardStroke, lineWidth: 1)
        )
    }
}

// MARK: - 主面板

struct PanelView: View {
    @ObservedObject var model: AppModel
    var renderMode = false
    @State private var pendingKill: ProcInfo?
    /// 实测出的内容高度，用来决定面板要不要滚动
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        // 必须在构建子视图之前设好，子视图里的 FS() 才拿得到正确倍率
        let _ = { UIScale.factor = CGFloat(model.settings.fontScale) }()

        VStack(spacing: model.settings.compactPanel ? 7 : 10) {
            header
            if model.showSettings {
                SettingsView(model: model, renderMode: renderMode)
            } else {
                mainContent
            }
            footer
        }
        .padding(model.settings.compactPanel ? 9 : 12)
        .frame(width: CGFloat(model.settings.panelWidth))
        .environment(\.compactPanel, model.settings.compactPanel)
        .background(Color.clear)
        .alert("结束这个进程？", isPresented: Binding(
            get: { pendingKill != nil },
            set: { if !$0 { pendingKill = nil } }
        ), presenting: pendingKill) { proc in
            Button("结束 \(proc.name)", role: .destructive) {
                if model.terminate(pid: proc.id, expecting: proc.name) {
                    model.lastActionMessage = "已结束 \(proc.name)，约释放 \(Fmt.bytes(proc.memory))。"
                } else {
                    model.lastActionMessage = "没能结束 \(proc.name)（可能需要权限）。"
                }
                pendingKill = nil
                model.tick()
            }
            Button("取消", role: .cancel) { pendingKill = nil }
        } message: { proc in
            Text("\(proc.name) 当前占用约 \(Fmt.bytes(proc.memory))。未保存的工作可能会丢失，确认要结束吗？")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: FS(18), weight: .semibold))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.hardwareInfo.modelName)
                    .font(.system(size: FS(13), weight: .semibold))
                Text("\(model.hardwareInfo.chip) · \(Fmt.bytes(model.hardwareInfo.totalMemory)) · macOS \(model.hardwareInfo.osVersion)")
                    .font(.system(size: FS(10.5))).foregroundStyle(Theme.secondary)
            }
            Spacer()
            Button {
                model.showSettings.toggle()
            } label: {
                Image(systemName: model.showSettings ? "xmark" : "slider.horizontal.3")
                    .font(.system(size: FS(12), weight: .medium))
            }
            .buttonStyle(.plain)
            .help(model.showSettings ? "返回" : "设置")
        }
    }

    /// 当前设置里勾选了哪些区块
    private func shows(_ s: PanelSection) -> Bool {
        guard !model.settings.panelSections.isEmpty else { return true }  // 全不选时兜底显示全部
        return model.settings.panelSections.contains(s)
    }

    private var contentStack: some View {
        VStack(spacing: model.settings.compactPanel ? 7 : 10) {
            if shows(.memory)      { memoryCard }
            if shows(.advice)      { adviceCard }
            if shows(.temperature) { temperatureCard }
            if shows(.fan)         { fanCard }
            if shows(.cpu)         { cpuCard }
            if shows(.summary)     { compactCard }
            if shows(.processes)   { processCard }
            if let msg = model.lastActionMessage {
                Text(msg)
                    .font(.system(size: FS(11)))
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)
            }
        }
        .padding(.bottom, 2)
        // 量一下真实高度，用来决定面板要不要滚动
        .background(
            GeometryReader { g in
                Color.clear.preference(key: ContentHeightKey.self, value: g.size.height)
            }
        )
    }

    /// 面板最多能长多高：贴着屏幕可用高度留点余量，让「一屏看全」尽可能成立
    private var maxPanelHeight: CGFloat {
        let visible = NSScreen.main?.visibleFrame.height ?? 900
        return max(360, visible - 120)
    }

    private var mainContent: some View {
        Group {
            if renderMode {
                // 离屏渲染时不能套 ScrollView：它的 fittingSize 不准，会把下面的卡片截掉
                contentStack
            } else {
                // 内容装得下就不滚：把上限放到屏幕高度，而不是写死一个矮值
                ScrollView(.vertical, showsIndicators: contentHeight > maxPanelHeight) {
                    contentStack
                }
                .frame(maxHeight: model.settings.autoFitPanel ? maxPanelHeight : 520)
                .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
            }
        }
    }

    // MARK: 内存

    private var memoryCard: some View {
        let m = model.snapshot.memory
        return Card(title: "内存") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Fmt.bytes(m.used))
                    .font(.system(size: FS(22), weight: .bold, design: .rounded))
                Text("/ \(Fmt.bytes(m.total))")
                    .font(.system(size: FS(12))).foregroundStyle(Theme.secondary)
                Spacer()
                Pill(text: "压力 \(m.pressureText)", color: m.pressureLevelEnum.color)
            }
            Bar(ratio: m.ratio, level: m.pressureLevelEnum, height: 7)
            HStack(spacing: 14) {
                MetricLine(label: "App", value: Fmt.bytes(m.app))
                MetricLine(label: "联动", value: Fmt.bytes(m.wired))
            }
            HStack(spacing: 14) {
                MetricLine(label: "压缩", value: Fmt.bytes(m.compressed))
                MetricLine(label: "缓存", value: Fmt.bytes(m.cached), color: Theme.secondary)
            }
            if m.swapUsed > 0 {
                MetricLine(label: "交换区", value: "\(Fmt.bytes(m.swapUsed)) / \(Fmt.bytes(m.swapTotal))",
                           color: m.pageOutsPerSec > 200 ? Level.warning.color : .primary)
            }
            MetricLine(label: "换页（进/出）",
                       value: "\(Fmt.one(m.pageInsPerSec))/\(Fmt.one(m.pageOutsPerSec)) 页/秒",
                       color: m.pageOutsPerSec > 200 ? Level.warning.color : Theme.secondary)
        }
    }

    // MARK: 建议（人性化：先诊断，再让用户决定）

    private var adviceCard: some View {
        let a = model.advice
        return Card {
            HStack(spacing: 8) {
                Image(systemName: a.level == .normal ? "checkmark.circle.fill"
                      : (a.level == .critical ? "exclamationmark.triangle.fill" : "info.circle.fill"))
                    .foregroundStyle(a.level.color)
                Text(a.headline).font(.system(size: FS(12.5), weight: .semibold))
                Spacer()
            }
            Text(a.detail)
                .font(.system(size: FS(11.5))).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !a.candidates.isEmpty {
                Text("建议考虑结束（你点才结束，不会自动动手）：")
                    .font(.system(size: FS(11))).foregroundStyle(Theme.secondary)
                    .padding(.top, 2)
                ForEach(a.candidates.prefix(3)) { p in
                    HStack(spacing: 8) {
                        Text(p.name).font(.system(size: FS(12))).lineLimit(1)
                        Spacer()
                        Text(Fmt.bytes(p.memory)).font(.system(size: FS(11), design: .monospaced))
                            .foregroundStyle(Theme.secondary)
                        Button("结束") { pendingKill = p }
                            .font(.system(size: FS(11)))
                            .buttonStyle(.borderless)
                            .foregroundStyle(Level.critical.color)
                    }
                }
            }

            Divider().opacity(0.4).padding(.vertical, 2)

            HStack(spacing: 8) {
                Button {
                    model.purgeMemory { _ in }
                } label: {
                    Label(model.busy ? "执行中…" : "释放可回收内存", systemImage: "arrow.down.circle")
                        .font(.system(size: FS(12)))
                }
                .disabled(model.busy)
                Spacer()
            }
            Text("说明：这只是让内核回收「缓存/可回收页」，不杀任何 App。如果没有很多缓存，释放效果就很小——这是正常现象，别信「一键清空内存」的噱头。")
                .font(.system(size: FS(10.5))).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 温度

    private var temperatureCard: some View {
        let t = model.snapshot.temperature
        return Card(title: "温度") {
            if t.sensorCount == 0 {
                Text("这台设备暂时读不到温度传感器。")
                    .font(.system(size: FS(11.5))).foregroundStyle(Theme.secondary)
            } else {
                HStack(spacing: 8) {
                    tempBox("CPU", t.cpu)
                    tempBox("GPU", t.gpu)
                    tempBox("SSD", t.ssd)
                    tempBox("电池", t.battery)
                }
                if let h = t.hottest {
                    MetricLine(label: "最高温 · \(h.name)", value: Fmt.temp(h.value),
                               color: Level.ofTemp(h.value).color)
                }
                MetricLine(label: "传感器数量", value: "\(t.sensorCount) 个", color: Theme.secondary)
            }
        }
    }

    private func tempBox(_ label: String, _ value: Double?) -> some View {
        VStack(spacing: 2) {
            Text(Fmt.temp(value))
                .font(.system(size: FS(16), weight: .semibold, design: .rounded))
                .foregroundStyle(Level.ofTemp(value).color)
            Text(label).font(.system(size: FS(10.5))).foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
    }

    // MARK: 风扇（只有带风扇的机型才出现，自动适配）

    @ViewBuilder
    private var fanCard: some View {
        if !model.snapshot.fans.isEmpty {
            Card(title: "风扇") {
                ForEach(model.snapshot.fans) { f in
                    let ratio = f.maxRPM.map { Double(f.rpm) / Double(max($0, 1)) } ?? 0
                    MetricLine(label: f.label,
                               value: "\(f.rpm) RPM" + (f.maxRPM.map { " · 上限 \($0)" } ?? ""),
                               color: ratio > 0.85 ? Level.warning.color : .primary)
                }
                Text("风扇转速来自 SMC，不需要管理员权限。")
                    .font(.system(size: FS(10.5))).foregroundStyle(Theme.secondary)
            }
        } else if model.hardwareInfo.hasFan {
            Card(title: "风扇") {
                Text("这台机型带风扇，但当前读不到转速。若你有这台机器，欢迎反馈帮我适配。")
                    .font(.system(size: FS(11.5))).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // MacBook Air 等无风扇机型：整块不显示，避免无效信息
    }

    // MARK: CPU

    private var cpuCard: some View {
        let c = model.snapshot.cpu
        return Card(title: "CPU") {
            HStack(alignment: .firstTextBaseline) {
                Text(Fmt.percent(c.usage * 100))
                    .font(.system(size: FS(20), weight: .bold, design: .rounded))
                    .foregroundStyle(Level.of(c.usage).color)
                Spacer()
                Text("负载 \(Fmt.one(c.load1)) · \(model.hardwareInfo.cpuCount) 核")
                    .font(.system(size: FS(11))).foregroundStyle(Theme.secondary)
            }
            Bar(ratio: c.usage, level: Level.of(c.usage), height: 6)
            if !c.perCore.isEmpty {
                HStack(spacing: 3) {
                    ForEach(Array(c.perCore.enumerated()), id: \.offset) { _, v in
                        Capsule()
                            .fill(Level.of(v).color)
                            .frame(height: 18 * max(0.12, v))
                            .frame(maxWidth: .infinity, alignment: .bottom)
                    }
                }
                .frame(height: 18)
            }
        }
    }

    // MARK: 网络 / 磁盘 / 电池

    private var compactCard: some View {
        let n = model.snapshot.network
        let d = model.snapshot.disk
        let b = model.snapshot.battery
        return Card {
            HStack(spacing: 14) {
                MetricLine(label: "下载", value: Fmt.rate(n.downPerSec), color: Level.normal.color)
                MetricLine(label: "上传", value: Fmt.rate(n.upPerSec), color: Color(red: 0.35, green: 0.6, blue: 0.95))
            }
            MetricLine(label: "磁盘", value: "\(Fmt.bytes(d.used)) / \(Fmt.bytes(d.total))")
            Bar(ratio: d.ratio, level: Level.of(d.ratio), height: 5)
            if b.present {
                HStack(spacing: 14) {
                    MetricLine(label: "电池", value: "\(b.percentage)% \(b.charging ? "· 充电中" : "")",
                               color: b.percentage <= 20 ? Level.warning.color : .primary)
                    if let c = b.cycleCount {
                        MetricLine(label: "循环", value: "\(c) 次")
                    }
                }
            }
        }
    }

    // MARK: 进程排行

    private var processCard: some View {
        Card(title: "内存占用排行") {
            if model.processes.isEmpty {
                Text("暂无数据").font(.system(size: FS(11.5))).foregroundStyle(Theme.secondary)
            } else {
                ForEach(model.processes.prefix(8)) { p in
                    let userLocked = model.settings.extraProtected.contains(p.name.lowercased())
                    HStack(spacing: 8) {
                        Text(p.name).font(.system(size: FS(12))).lineLimit(1)
                        if p.isProtected {
                            Pill(text: userLocked ? "已锁定" : "保护", color: Theme.secondary)
                        }
                        Spacer(minLength: 6)
                        Text(Fmt.bytes(p.memory))
                            .font(.system(size: FS(11), design: .monospaced))
                            .foregroundStyle(Theme.secondary)

                        if p.isProtected {
                            // 用户自己加的锁可以解锁；系统级的保护名单不给解
                            if userLocked {
                                Button {
                                    model.settings.extraProtected.removeAll { $0 == p.name.lowercased() }
                                    model.tick()
                                } label: {
                                    Image(systemName: "lock.fill")
                                        .font(.system(size: FS(10.5)))
                                        .foregroundStyle(Color.accentColor)
                                }
                                .buttonStyle(.plain)
                                .help("取消「永不清理」：\(p.name)")
                            }
                        } else {
                            Button {
                                let n = p.name.lowercased()
                                if !model.settings.extraProtected.contains(n) {
                                    model.settings.extraProtected.append(n)
                                }
                                model.tick()
                            } label: {
                                Image(systemName: "lock.open")
                                    .font(.system(size: FS(10.5)))
                                    .foregroundStyle(Theme.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("把 \(p.name) 设为「永远保留」，连同自动清理也绝不碰它")

                            Button {
                                pendingKill = p
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: FS(11)))
                                    .foregroundStyle(Level.critical.color.opacity(0.8))
                            }
                            .buttonStyle(.plain)
                            .help("结束 \(p.name)")
                        }
                    }
                }
                Text("点 🔓 把某个程序设成「永远保留」——它永远不会被任何清理动作碰到。")
                    .font(.system(size: FS(10.5))).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: FS(10))).foregroundStyle(Theme.secondary)
            Text(model.snapshot.timestamp, style: .time)
                .font(.system(size: FS(10))).foregroundStyle(Theme.secondary)
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: model.settings.cleanupMode.icon).font(.system(size: FS(9)))
                Text("清理：\(model.settings.cleanupMode.title)").font(.system(size: FS(10)))
            }
            .foregroundStyle(model.settings.cleanupMode == .auto ? Level.warning.color : Theme.secondary)
            Spacer()
            Text("左键面板 · 右键菜单")
                .font(.system(size: FS(10))).foregroundStyle(Theme.secondary)
        }
    }
}

// MARK: - 设置面板

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var renderMode = false
    @State private var newProtected = ""

    @ViewBuilder
    var body: some View {
        if renderMode {
            settingsStack
        } else {
            ScrollView(.vertical, showsIndicators: false) { settingsStack }
                .frame(maxHeight: 460)
        }
    }

    private var settingsStack: some View {
        VStack(spacing: 10) {
                Card(title: "刷新") {
                    HStack {
                        Text("刷新间隔").font(.system(size: FS(12)))
                        Spacer()
                        Text("\(Int(model.settings.interval)) 秒")
                            .font(.system(size: FS(12), design: .monospaced)).foregroundStyle(Theme.secondary)
                    }
                    Slider(value: $model.settings.interval, in: 1...10, step: 1) { _ in
                        model.reschedule()
                    }
                }

                Card(title: "菜单栏显示") {
                    Toggle("显示图标", isOn: $model.settings.showIcon).font(.system(size: FS(12)))
                    ForEach(MenuBarItem.allCases) { item in
                        Toggle(item.title, isOn: binding(for: item)).font(.system(size: FS(12)))
                    }
                    Text("可多选，按从左到右顺序显示。")
                        .font(.system(size: FS(10.5))).foregroundStyle(Theme.secondary)
                }

                Card(title: "面板显示") {
                    // 宽度：越宽越不容易换行，整体就越矮
                    HStack {
                        Text("宽度").font(.system(size: FS(12)))
                        Spacer()
                        Picker("", selection: $model.settings.panelWidth) {
                            Text("窄").tag(340.0)
                            Text("标准").tag(380.0)
                            Text("宽").tag(460.0)
                            Text("很宽").tag(560.0)
                        }
                        .labelsHidden()
                        .frame(width: 110)
                    }

                    // 字号：小一点就能少滚动
                    HStack {
                        Text("字号").font(.system(size: FS(12)))
                        Spacer()
                        Picker("", selection: $model.settings.fontScale) {
                            Text("紧凑").tag(0.85)
                            Text("标准").tag(1.0)
                            Text("宽松").tag(1.15)
                        }
                        .labelsHidden()
                        .frame(width: 110)
                    }

                    Toggle("紧凑间距", isOn: $model.settings.compactPanel)
                        .font(.system(size: FS(12)))
                    Toggle("自动撑开高度（尽量一屏看全）", isOn: $model.settings.autoFitPanel)
                        .font(.system(size: FS(12)))

                    Text("显示哪些区块（不想要的关掉，就不用滚动了）")
                        .font(.system(size: FS(10.5))).foregroundStyle(Theme.secondary)
                        .padding(.top, 2)
                    ForEach(PanelSection.allCases) { sec in
                        Toggle(sec.title, isOn: sectionBinding(for: sec))
                            .font(.system(size: FS(12)))
                    }

                    HStack(spacing: 8) {
                        Button("只留内存+温度") {
                            model.settings.panelSections = [.memory, .temperature]
                        }
                        .font(.system(size: FS(11)))
                        Button("全部显示") {
                            model.settings.panelSections = PanelSection.allCases
                        }
                        .font(.system(size: FS(11)))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
                }

                Card(title: "悬浮小窗") {
                    Toggle("在桌面上常驻一个小窗", isOn: $model.settings.showFloating).font(.system(size: FS(12)))
                    Text("菜单栏图标被系统藏起来时的备选方案：小窗可以任意拖动，永远置顶，显示的内容和菜单栏一致。")
                        .font(.system(size: FS(10.5))).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Card(title: "内存清理方式") {
                    ForEach(CleanupMode.allCases) { mode in
                        Button {
                            model.settings.cleanupMode = mode
                        } label: {
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: model.settings.cleanupMode == mode ? "largecircle.fill.circle" : "circle")
                                    .font(.system(size: FS(12)))
                                    .foregroundStyle(model.settings.cleanupMode == mode ? Color.accentColor : Theme.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mode.title).font(.system(size: FS(12.5), weight: .semibold))
                                        .foregroundStyle(.primary)
                                    Text(mode.detail)
                                        .font(.system(size: FS(10.5)))
                                        .foregroundStyle(Theme.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .multilineTextAlignment(.leading)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if model.settings.cleanupMode == .auto {
                        Text("自动模式护栏：只清「后台进程」；你正在用的 App、当前前台 App、保护名单一律不动；最少 10 分钟才动一次，每次最多 2 个，且结束前会再核对一次。")
                            .font(.system(size: FS(10.5)))
                            .foregroundStyle(Level.warning.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Card(title: "本机自适应") {
                    MetricLine(label: "机型", value: model.hardwareInfo.modelName)
                    if !model.hardwareInfo.modelNumber.isEmpty {
                        MetricLine(label: "监管型号", value: model.hardwareInfo.modelNumber)
                    }
                    MetricLine(label: "芯片", value: model.hardwareInfo.chip)
                    MetricLine(label: "内存 / 核心", value: "\(Fmt.bytes(model.hardwareInfo.totalMemory)) · \(model.hardwareInfo.cpuCount) 核")
                    MetricLine(label: "大户判定基准", value: Fmt.bytes(model.heavyProcessThreshold),
                               color: Theme.secondary)
                    Text("阈值随你的内存自动调整，不写死。8GB 与 128GB 机器用的不是同一套标准。")
                        .font(.system(size: FS(10.5))).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Card(title: "开机自启") {
                    Toggle("登录时自动启动 PulseBar", isOn: $model.settings.launchAtLogin).font(.system(size: FS(12)))
                }

                Card(title: "「永远保留」名单") {
                    Text("列在这里的程序，**永远不会**被清理——包括自动模式，也会跳过它们。系统进程、微信、输入法已默认保护。")
                        .font(.system(size: FS(10.5))).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("最方便的做法：回到面板的「内存占用排行」，点某一行左边的 🔓 图标，就能把它加进来。")
                        .font(.system(size: FS(10.5))).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !model.settings.extraProtected.isEmpty {
                        FlowRow(items: model.settings.extraProtected) { name in
                            model.settings.extraProtected.removeAll { $0 == name }
                        }
                    } else {
                        Text("（还没有手动添加的）")
                            .font(.system(size: FS(10.5))).foregroundStyle(Theme.secondary)
                    }
                    HStack(spacing: 6) {
                        TextField("也可以手动输入名称，如 adobe", text: $newProtected)
                            .textFieldStyle(.roundedBorder).font(.system(size: FS(12)))
                        Button("加入") {
                            let t = newProtected.trimmingCharacters(in: .whitespaces).lowercased()
                            if !t.isEmpty && !model.settings.extraProtected.contains(t) {
                                model.settings.extraProtected.append(t)
                            }
                            newProtected = ""
                        }
                        .font(.system(size: FS(12)))
                    }
                }
            }
            .padding(.bottom, 2)
    }

    private func binding(for item: MenuBarItem) -> Binding<Bool> {
        Binding(
            get: { model.settings.menuBarItems.contains(item) },
            set: { on in
                if on {
                    if !model.settings.menuBarItems.contains(item) { model.settings.menuBarItems.append(item) }
                } else {
                    model.settings.menuBarItems.removeAll { $0 == item }
                }
            }
        )
    }

    /// 面板区块的开关。
    /// 注意：从「全部勾选」里取消一个时，不能依赖空数组兜底，否则用户会以为开关失灵。
    /// 所以这里始终是显式的白名单，且至少保留一个区块。
    private func sectionBinding(for sec: PanelSection) -> Binding<Bool> {
        Binding(
            get: { model.settings.panelSections.contains(sec) },
            set: { on in
                var cur = model.settings.panelSections
                if on {
                    if !cur.contains(sec) { cur.append(sec) }
                } else {
                    cur.removeAll { $0 == sec }
                    if cur.isEmpty { return }   // 一个都不剩就忽略这次操作，避免出现空面板
                }
                // 按枚举顺序规范化，保证面板里的顺序稳定
                model.settings.panelSections = PanelSection.allCases.filter { cur.contains($0) }
            }
        )
    }
}

struct FlowRow: View {
    var items: [String]
    var onRemove: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { name in
                HStack(spacing: 6) {
                    Text(name).font(.system(size: FS(11)))
                    Spacer()
                    Button {
                        onRemove(name)
                    } label: {
                        Image(systemName: "minus.circle").font(.system(size: FS(11)))
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.secondary)
                }
            }
        }
    }
}
