import Foundation
import Darwin
import AppKit

// libproc 未在 Darwin 模块导出，手动声明
@_silgen_name("proc_listallpids") func proc_listallpids(_ b: UnsafeMutableRawPointer?, _ s: Int32) -> Int32
@_silgen_name("proc_pid_rusage")  func proc_pid_rusage(_ pid: Int32, _ flavor: Int32, _ b: UnsafeMutableRawPointer?) -> Int32
@_silgen_name("proc_pidpath")     func proc_pidpath(_ pid: Int32, _ b: UnsafeMutableRawPointer?, _ s: UInt32) -> Int32
@_silgen_name("proc_name")        func proc_name(_ pid: Int32, _ b: UnsafeMutableRawPointer?, _ s: UInt32) -> Int32

// MARK: - 进程模型

struct ProcInfo: Identifiable {
    let id: Int32          // pid
    var name: String
    var path: String
    var memory: Int64      // phys_footprint
    var cpu: Double        // 0...1 单核归一说明见下
    var isProtected: Bool

    /// CPU 显示用（相对整机，0...100%×核数 归一为百分比）
    var cpuPercent: Double { cpu * 100 }
}

// MARK: - 保护名单

/// 默认保护：这些进程永远不会被「一键优化」选中，也不会出现在可结束列表里。
/// 用户可以自己在设置里追加（比如把某个 App 加进来）。
enum ProcessGuard {
    /// 精确匹配的进程名（小写）
    static let protectedNames: Set<String> = [
        "windowserver", "loginwindow", "dock", "finder", "systemuiserver",
        "controlcenter", "notificationcenter", "spotlight", "mds", "mdworker",
        "kernel_task", "launchd", "logd", "runningboardd", "coreservicesd",
        "sharingd", "airportd", "powerd", "configd", "opendirectoryd",
        "pulsebar", "statbar",
    ]

    /// 包含即视为敏感（聊天/输入法/音乐/后台同步），避免误杀用户正在用的东西
    static let protectedKeywords: [String] = [
        "wechat", "weixin", "微信",
        "inputmethod", "input method", "sogou", "baidu", "ime",
        "music", "spotify", "netease", "qqmusic",
        "1password", "keychain", "bitwarden",
        "timemachine", "backupd", "icloud", "bird", "cloudd",
        "mds_stores", "fseventsd",
    ]

    static func isProtected(_ name: String, path: String) -> Bool {
        let lower = name.lowercased()
        if protectedNames.contains(lower) { return true }
        for kw in protectedKeywords where lower.contains(kw) { return true }
        let pathLower = path.lowercased()
        if pathLower.hasPrefix("/system/") || pathLower.hasPrefix("/usr/libexec/")
            || pathLower.hasPrefix("/usr/sbin/") { return true }
        return false
    }
}

// MARK: - 采样

final class ProcessSampler {
    private var lastCPU: [Int32: UInt64] = [:]
    private var lastTime = Date()

    /// 返回按内存占用降序排列的进程列表
    /// - Parameter coreCount: 本机核心数，用于归一化单进程 CPU 上限（不同机型差异很大）
    func sample(limit: Int = 12, coreCount: Int = 8, extraProtected: Set<String> = []) -> [ProcInfo] {
        let now = Date()
        let dt = max(0.2, now.timeIntervalSince(lastTime))
        lastTime = now

        let pidCount = proc_listallpids(nil, 0)
        guard pidCount > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(pidCount))
        let actual = pids.withUnsafeMutableBufferPointer { buf -> Int32 in
            proc_listallpids(buf.baseAddress, Int32(buf.count * MemoryLayout<Int32>.size))
        }
        guard actual > 0 else { return [] }

        var results: [ProcInfo] = []
        var newCPU: [Int32: UInt64] = [:]

        for pid in pids where pid > 0 {
            var buf = [UInt8](repeating: 0, count: 1024)
            let rc = buf.withUnsafeMutableBytes { proc_pid_rusage(pid, 4, $0.baseAddress) }
            guard rc == 0 else { continue }

            let (userTime, sysTime, footprint): (UInt64, UInt64, UInt64) = buf.withUnsafeBytes { raw in
                (raw.loadUnaligned(fromByteOffset: 16, as: UInt64.self),
                 raw.loadUnaligned(fromByteOffset: 24, as: UInt64.self),
                 raw.loadUnaligned(fromByteOffset: 72, as: UInt64.self))
            }
            newCPU[pid] = userTime &+ sysTime

            guard footprint > 0 else { continue }

            var pathBuf = [UInt8](repeating: 0, count: 4096)
            let pLen = pathBuf.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, 4096) }
            let path = pLen > 0 ? String(cString: pathBuf) : ""

            var nameBuf = [UInt8](repeating: 0, count: 256)
            let nLen = nameBuf.withUnsafeMutableBytes { proc_name(pid, $0.baseAddress, 256) }
            var name = nLen > 0 ? String(cString: nameBuf) : ""
            if name.isEmpty { name = (path as NSString).lastPathComponent }
            if name.isEmpty { continue }

            var cpu: Double = 0
            if let prev = lastCPU[pid], newCPU[pid]! >= prev {
                let delta = Double(newCPU[pid]! - prev) / 1_000_000_000 // 秒
                cpu = (delta / dt).clamped(0, Double(coreCount))        // 上限随核心数自适应
            }

            let protected = ProcessGuard.isProtected(name, path: path)
                || extraProtected.contains(name.lowercased())
            results.append(ProcInfo(id: pid, name: name, path: path,
                                       memory: Int64(bitPattern: footprint),
                                       cpu: cpu, isProtected: protected))
        }

        lastCPU = newCPU
        return results.sorted { $0.memory > $1.memory }.prefix(limit).map { $0 }
    }
}

// MARK: - 自动清理的护栏判断

extension ProcInfo {
    /// 是否是「用户正在用的 App」——即 Dock 里有图标、有窗口的常规应用。
    /// 自动清理模式下**永远不会**碰这类进程，只清后台守护/辅助进程。
    var isUserFacingApp: Bool {
        guard let app = NSRunningApplication(processIdentifier: id) else { return false }
        return app.activationPolicy == .regular
    }

    /// 是否是当前最前台、正在被输入的那个 App
    var isFrontmostApp: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == id
    }

    /// 是否可以被自动清理：非保护、非用户 App、非前台
    var isAutoCleanEligible: Bool {
        !isProtected && !isUserFacingApp && !isFrontmostApp
    }
}
