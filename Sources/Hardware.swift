import Foundation

// MARK: - 机型 / 芯片信息

struct HardwareInfo {
    var modelName: String       // 例如 MacBook Air (M1, 2020)
    var modelNumber: String     // 监管型号，如 A2337（查不到时为空）
    var modelIdentifier: String // 如 MacBookAir10,1
    var chip: String            // Apple M1 / M2 Pro / M4 Max …（来自 sysctl，永远准确）
    var totalMemory: Int64
    var cpuCount: Int
    var osVersion: String

    /// 该机型是否带风扇（MacBook Air 全系被动散热、无风扇）
    var hasFan: Bool

    /// 内存档位文案，用于「按你的机器自适应」的提示
    var memoryTier: String {
        let gb = Double(totalMemory) / 1_073_741_824
        if gb >= 100 { return "大内存机型" }
        if gb >= 30 { return "高配内存" }
        if gb >= 14 { return "标准内存" }
        return "基础内存"
    }

    var summary: String { "\(chip) · \(Fmt.bytes(totalMemory)) · \(cpuCount) 核" }
}

enum Hardware {
    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static func sysctlInt(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    /// 是否为 Apple 芯片
    static var isAppleSilicon: Bool {
        var v: Int32 = 0
        var s = MemoryLayout<Int32>.size
        sysctlbyname("hw.optional.arm64", &v, &s, nil, 0)
        return v == 1
    }

    /// 机型标识 -> (市场名, 监管型号)
    /// 覆盖 Apple 芯片全线：MacBook Air / MacBook Pro / Mac mini / iMac / Mac Studio / Mac Pro。
    /// 表里没有的机型会自动回退成机型标识显示，不影响任何功能。
    private static let modelMap: [String: (name: String, number: String)] = [
        // ── MacBook Air ──────────────────────────────
        "MacBookAir10,1": ("MacBook Air (M1, 2020)", "A2337"),
        "Mac14,2":        ("MacBook Air (M2, 2022)", "A2681"),
        "Mac14,15":       ("MacBook Air 15\" (M2, 2023)", "A2941"),
        "Mac15,12":       ("MacBook Air 13\" (M3, 2024)", "A3113"),
        "Mac15,13":       ("MacBook Air 15\" (M3, 2024)", "A3114"),
        "Mac16,12":       ("MacBook Air 13\" (M4, 2025)", "A3240"),
        "Mac16,13":       ("MacBook Air 15\" (M4, 2025)", "A3241"),

        // ── MacBook Pro ──────────────────────────────
        "MacBookPro17,1": ("MacBook Pro 13\" (M1, 2020)", "A2338"),
        "MacBookPro18,3": ("MacBook Pro 14\" (M1 Pro, 2021)", "A2442"),
        "MacBookPro18,4": ("MacBook Pro 14\" (M1 Max, 2021)", "A2442"),
        "MacBookPro18,1": ("MacBook Pro 16\" (M1 Pro, 2021)", "A2485"),
        "MacBookPro18,2": ("MacBook Pro 16\" (M1 Max, 2021)", "A2485"),
        "Mac14,5":        ("MacBook Pro 14\" (M2 Pro, 2023)", "A2779"),
        "Mac14,9":        ("MacBook Pro 14\" (M2 Max, 2023)", "A2779"),
        "Mac14,6":        ("MacBook Pro 16\" (M2 Pro, 2023)", "A2780"),
        "Mac14,10":       ("MacBook Pro 16\" (M2 Max, 2023)", "A2780"),
        "Mac15,3":        ("MacBook Pro 14\" (M3, 2023)", "A2918"),
        "Mac15,6":        ("MacBook Pro 14\" (M3 Pro, 2023)", "A2992"),
        "Mac15,8":        ("MacBook Pro 14\" (M3 Max, 2023)", "A2992"),
        "Mac15,10":       ("MacBook Pro 14\" (M3 Max, 2023)", "A2992"),
        "Mac15,7":        ("MacBook Pro 16\" (M3 Pro, 2023)", "A2991"),
        "Mac15,9":        ("MacBook Pro 16\" (M3 Max, 2023)", "A2991"),
        "Mac15,11":       ("MacBook Pro 16\" (M3 Max, 2023)", "A2991"),
        "Mac16,1":        ("MacBook Pro 14\" (M4, 2024)", "A3401"),
        "Mac16,3":        ("MacBook Pro 14\" (M4 Pro, 2024)", "A3403"),
        "Mac16,6":        ("MacBook Pro 14\" (M4 Max, 2024)", "A3405"),
        "Mac16,5":        ("MacBook Pro 16\" (M4 Pro, 2024)", "A3403"),
        "Mac16,7":        ("MacBook Pro 16\" (M4 Max, 2024)", "A3405"),

        // ── Mac mini ─────────────────────────────────
        "Macmini9,1":     ("Mac mini (M1, 2020)", "A2348"),
        "Mac14,3":        ("Mac mini (M2, 2023)", "A2686"),
        "Mac14,12":       ("Mac mini (M2 Pro, 2023)", "A2816"),
        "Mac16,10":       ("Mac mini (M4, 2024)", "A3231"),
        "Mac16,11":       ("Mac mini (M4 Pro, 2024)", "A3232"),

        // ── iMac ─────────────────────────────────────
        "iMac21,1":       ("iMac 24\" (M1, 2021)", "A2438"),
        "iMac21,2":       ("iMac 24\" (M1, 2021)", "A2439"),
        "Mac15,4":        ("iMac 24\" (M3, 2023)", "A2873"),
        "Mac15,5":        ("iMac 24\" (M3, 2023)", "A2874"),
        "Mac16,2":        ("iMac 24\" (M4, 2024)", "A3224"),

        // ── Mac Studio ───────────────────────────────
        "Mac13,1":        ("Mac Studio (M1 Max, 2022)", "A2615"),
        "Mac13,2":        ("Mac Studio (M1 Ultra, 2022)", "A2615"),
        "Mac14,13":       ("Mac Studio (M2 Max, 2023)", "A2901"),
        "Mac14,14":       ("Mac Studio (M2 Ultra, 2023)", "A2901"),
        "Mac15,14":       ("Mac Studio (M3 Ultra, 2025)", ""),

        // ── Mac Pro ──────────────────────────────────
        "Mac14,8":        ("Mac Pro (M2 Ultra, 2023)", "A2786"),
    ]

    static func load() -> HardwareInfo {
        let ident = sysctlString("hw.model") ?? "Mac"
        let mapped = modelMap[ident]
        let chip = sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"
        let mem = sysctlInt("hw.memsize") ?? 0
        let ncpu = Int(sysctlInt("hw.ncpu") ?? 0)
        let osv = ProcessInfo.processInfo.operatingSystemVersionString
            .replacingOccurrences(of: "Version ", with: "")
        return HardwareInfo(
            modelName: mapped?.name ?? ident,
            modelNumber: mapped?.number ?? "",
            modelIdentifier: ident,
            chip: chip,
            totalMemory: mem,
            cpuCount: max(1, ncpu),
            osVersion: osv,
            hasFan: !ident.hasPrefix("MacBookAir")
        )
    }
}
