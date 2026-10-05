import AppKit
import Foundation

// 顶层代码入口（存在 main.swift 时允许顶层语句）

let args = CommandLine.arguments

// 1) --selfcheck：命令行自检，打印所有指标，确认数据合理
if args.contains("--selfcheck") {
    let sampler = MetricsSampler()
    _ = sampler.sample()
    let s = sampler.sample()
    let hw = Hardware.load()

    let t = s.temperature
    print("机型: \(hw.modelName) \(hw.modelNumber) [\(hw.modelIdentifier)]")
    print("芯片: \(hw.chip) · \(Fmt.bytes(hw.totalMemory)) · \(hw.cpuCount) 核 · macOS \(hw.osVersion)")
    print("内存: 已用 \(Fmt.bytes(s.memory.used)) / \(Fmt.bytes(s.memory.total))  压力=\(s.memory.pressureText)  交换=\(Fmt.bytes(s.memory.swapUsed))")
    print("       App=\(Fmt.bytes(s.memory.app)) 联动=\(Fmt.bytes(s.memory.wired)) 压缩=\(Fmt.bytes(s.memory.compressed)) 缓存=\(Fmt.bytes(s.memory.cached)) 空闲=\(Fmt.bytes(s.memory.free))")
    print("      换页: 进 \(Fmt.one(s.memory.pageInsPerSec))/s 出 \(Fmt.one(s.memory.pageOutsPerSec))/s")
    print("CPU: \(Fmt.percent(s.cpu.usage * 100))  负载 \(Fmt.one(s.cpu.load1))  核心数 \(s.cpu.perCore.count)")
    print("温度: CPU=\(Fmt.temp(t.cpu)) GPU=\(Fmt.temp(t.gpu)) SSD=\(Fmt.temp(t.ssd)) 电池=\(Fmt.temp(t.battery))  传感器=\(t.sensorCount)")
    if let h = t.hottest { print("      最高温: \(h.name) = \(Fmt.temp(h.value))") }
    print("磁盘: \(Fmt.bytes(s.disk.used)) / \(Fmt.bytes(s.disk.total)) (\(Fmt.percent(s.disk.ratio * 100)))")
    print("网络: ↓\(Fmt.rate(s.network.downPerSec)) ↑\(Fmt.rate(s.network.upPerSec))")
    print("电池: \(s.battery.present ? "\(s.battery.percentage)% 循环\(s.battery.cycleCount.map(String.init) ?? "?")次" : "无")")
    if s.fans.isEmpty {
        print("风扇: 无（\(hw.hasFan ? "该机型应有风扇，但本次读不到" : "本机为被动散热机型")）")
    } else {
        print("风扇: " + s.fans.map { "\($0.label)=\($0.rpm)RPM" }.joined(separator: "  "))
    }

    let procs = ProcessSampler().sample(limit: 6)
    print("内存大户:")
    for p in procs {
        print("      \(p.name)  \(Fmt.bytes(p.memory))\(p.isProtected ? "  [保护]" : "")")
    }
    exit(0)
}

// 2) --render 输出png [--settings] [--demo]
if let idx = args.firstIndex(of: "--render"), idx + 1 < args.count {
    let settingsMode = args.contains("--settings")
    let demoMode = args.contains("--demo")
    RenderMode.run(output: args[idx + 1], settings: settingsMode, demo: demoMode)
    exit(0)
}

// 3) 正常启动菜单栏应用
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
