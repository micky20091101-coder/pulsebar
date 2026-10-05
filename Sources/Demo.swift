import Foundation

// MARK: - 演示数据
//
// 官网截图不能用开发者自己的机器（会暴露真实机型与正在跑的软件）。
// `--render --demo` 时用这份虚构的「普通用户」数据渲染，机型取一台更主流的 M1 Pro。

enum DemoData {
    static let hardware = HardwareInfo(
        modelName: "MacBook Pro 14\" (M1 Pro, 2021)",
        modelNumber: "A2442",
        modelIdentifier: "MacBookPro18,3",
        chip: "Apple M1 Pro",
        totalMemory: 16 * 1_073_741_824,
        cpuCount: 10,
        osVersion: "15.3 (24D60)",
        hasFan: true
    )

    static func snapshot() -> SystemSnapshot {
        var s = SystemSnapshot()

        s.memory.used = 11_951_595_520          // ≈ 11.1 GB
        s.memory.total = 17_179_869_184         // 16 GB
        s.memory.app = 5_368_709_120
        s.memory.wired = 2_254_857_830
        s.memory.compressed = 1_877_048_320
        s.memory.cached = 3_328_696_320
        s.memory.free = 1_181_116_416
        s.memory.pressureLevel = 2
        s.memory.swapUsed = 1_288_490_188
        s.memory.swapTotal = 3_221_225_472
        s.memory.pageInsPerSec = 12
        s.memory.pageOutsPerSec = 3

        s.cpu.usage = 0.24
        s.cpu.perCore = [0.42, 0.18, 0.31, 0.12, 0.08, 0.55, 0.22, 0.10, 0.06, 0.04]
        s.cpu.load1 = 2.41

        s.disk.total = 494_384_795_648
        s.disk.free = 192_348_962_816

        s.network.downPerSec = 1_887_436
        s.network.upPerSec = 96_256

        s.battery.present = true
        s.battery.percentage = 76
        s.battery.charging = false
        s.battery.condition = "Normal"
        s.battery.cycleCount = 143

        s.temperature.cpu = 52
        s.temperature.gpu = 47
        s.temperature.ssd = 41
        s.temperature.battery = 31
        s.temperature.sensorCount = 58
        s.temperature.hottest = ("PMU tdie3", 58)

        s.fans = [FanSnapshot(id: 0, rpm: 1798, minRPM: 1200, maxRPM: 5778)]

        s.timestamp = Date()
        return s
    }

    /// 一个普通用户的日常进程组合（含被保护的微信）
    static let processes: [ProcInfo] = [
        ProcInfo(id: 501, name: "Google Chrome", path: "/Applications/Google Chrome.app", memory: 2_147_483_648, cpu: 0.11, isProtected: false),
        ProcInfo(id: 502, name: "Adobe Photoshop 2025", path: "/Applications/Adobe Photoshop 2025.app", memory: 1_932_735_283, cpu: 0.07, isProtected: false),
        ProcInfo(id: 503, name: "Xcode", path: "/Applications/Xcode.app", memory: 1_503_238_553, cpu: 0.19, isProtected: false),
        ProcInfo(id: 504, name: "微信", path: "/Applications/WeChat.app", memory: 638_582_374, cpu: 0.02, isProtected: true),
        ProcInfo(id: 505, name: "Slack", path: "/Applications/Slack.app", memory: 512_854_016, cpu: 0.03, isProtected: false),
        ProcInfo(id: 506, name: "Figma", path: "/Applications/Figma.app", memory: 436_207_616, cpu: 0.04, isProtected: false),
        ProcInfo(id: 507, name: "Final Cut Pro", path: "/Applications/Final Cut Pro.app", memory: 379_191_296, cpu: 0.01, isProtected: false),
        ProcInfo(id: 508, name: "Dropbox", path: "/Applications/Dropbox.app", memory: 284_164_096, cpu: 0.01, isProtected: false),
    ]
}

extension AppModel {
    func applyDemoData() {
        setHardware(DemoData.hardware)
        snapshot = DemoData.snapshot()
        processes = DemoData.processes
    }
}
