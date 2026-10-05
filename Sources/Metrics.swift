import Foundation
import Darwin
import IOKit
import IOKit.ps

// MARK: - 数据模型

struct MemorySnapshot {
    var used: Int64 = 0          // 活动监视器口径：App + Wired + Compressed
    var total: Int64 = 0
    var app: Int64 = 0
    var wired: Int64 = 0
    var compressed: Int64 = 0
    var cached: Int64 = 0
    var free: Int64 = 0
    var pressureLevel: Int32 = 1 // 1 正常 / 2 警告 / 4 严重
    var swapUsed: Int64 = 0
    var swapTotal: Int64 = 0
    var pageInsPerSec: Double = 0
    var pageOutsPerSec: Double = 0

    var ratio: Double { total > 0 ? Double(used) / Double(total) : 0 }
    var pressureText: String {
        switch pressureLevel { case 2: return "偏高"; case 4: return "严重"; default: return "正常" }
    }
    var pressureLevelEnum: Level {
        switch pressureLevel { case 4: return .critical; case 2: return .warning; default: return .normal }
    }
}

struct CPUSnapshot {
    var usage: Double = 0            // 0...1 总体
    var perCore: [Double] = []       // 每核心 0...1
    var load1: Double = 0
}

struct DiskSnapshot {
    var total: Int64 = 0
    var free: Int64 = 0
    var used: Int64 { max(0, total - free) }
    var ratio: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

struct NetworkSnapshot {
    var downPerSec: Double = 0
    var upPerSec: Double = 0
    var totalDown: Int64 = 0
    var totalUp: Int64 = 0
}

struct BatterySnapshot {
    var present = false
    var percentage: Int = 0
    var charging = false
    var cycleCount: Int? = nil
    var condition: String = ""
}

struct TemperatureSnapshot {
    var cpu: Double?
    var gpu: Double?
    var ssd: Double?
    var battery: Double?
    var sensorCount: Int = 0
    /// 全系统最高温（排查异常时最有用）
    var hottest: (name: String, value: Double)? = nil
}

struct SystemSnapshot {
    var memory = MemorySnapshot()
    var cpu = CPUSnapshot()
    var disk = DiskSnapshot()
    var network = NetworkSnapshot()
    var battery = BatterySnapshot()
    var temperature = TemperatureSnapshot()
    var fans: [FanSnapshot] = []
    var timestamp = Date()
}

// MARK: - 采样器

final class MetricsSampler {
    private var lastCPU: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []
    private var lastNet: (down: Int64, up: Int64) = (0, 0)
    private var lastSwap: (ins: Int64, outs: Int64) = (0, 0)
    private var lastSwapTime = Date()
    private let tempReader = TemperatureReader.shared

    func sample() -> SystemSnapshot {
        var s = SystemSnapshot()
        let now = Date()
        let dt = max(0.2, now.timeIntervalSince(lastSwapTime))

        s.memory = sampleMemory(dt: dt)
        s.cpu = sampleCPU()
        s.disk = sampleDisk()
        s.network = sampleNetwork(dt: dt)
        s.battery = sampleBattery()
        s.temperature = tempReader.read()
        s.fans = FanReader.shared.read()
        s.timestamp = now

        lastSwapTime = now
        return s
    }

    // MARK: 内存

    private func sampleMemory(dt: TimeInterval) -> MemorySnapshot {
        var m = MemorySnapshot()
        m.total = Hardware.sysctlInt("hw.memsize") ?? 0

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        var pageSizeRaw: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSizeRaw)
        let page = Int64(pageSizeRaw)

        if kr == KERN_SUCCESS {
            m.app = max(0, (Int64(stats.internal_page_count) - Int64(stats.purgeable_count)) * page)
            m.wired = Int64(stats.wire_count) * page
            m.compressed = Int64(stats.compressor_page_count) * page
            m.cached = (Int64(stats.external_page_count) + Int64(stats.purgeable_count)) * page
            m.free = (Int64(stats.free_count) + Int64(stats.speculative_count)) * page
            m.used = m.app + m.wired + m.compressed

            let ins = Int64(stats.pageins)
            let outs = Int64(stats.pageouts)
            if lastSwap.ins > 0 {
                m.pageInsPerSec = max(0, Double(ins - lastSwap.ins) / dt)
                m.pageOutsPerSec = max(0, Double(outs - lastSwap.outs) / dt)
            }
            lastSwap = (ins, outs)
        }

        var level: Int32 = 1
        var lsz = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &lsz, nil, 0) == 0 {
            m.pressureLevel = level
        }

        var swap = xsw_usage()
        var ssz = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &ssz, nil, 0) == 0 {
            m.swapUsed = Int64(swap.xsu_used)
            m.swapTotal = Int64(swap.xsu_total)
        }
        return m
    }

    // MARK: CPU

    private func sampleCPU() -> CPUSnapshot {
        var c = CPUSnapshot()
        var cpuInfo: processor_info_array_t?
        var numCpu: mach_msg_type_number_t = 0
        var numCpuInfo: mach_msg_type_number_t = 0
        let r = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCpu, &cpuInfo, &numCpuInfo)
        defer {
            if let info = cpuInfo {
                vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                              vm_size_t(Int(numCpuInfo) * MemoryLayout<integer_t>.size))
            }
        }
        guard r == KERN_SUCCESS, let info = cpuInfo else { return c }

        let stride = Int(CPU_STATE_MAX)
        var cores: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []
        for i in 0..<Int(numCpu) {
            let base = i * stride
            cores.append((UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                          UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                          UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                          UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])))
        }

        if lastCPU.count == cores.count {
            var perCore: [Double] = []
            var totalBusy: Double = 0
            var totalAll: Double = 0
            for i in 0..<cores.count {
                let u = Double(cores[i].user &- lastCPU[i].user)
                let sy = Double(cores[i].system &- lastCPU[i].system)
                let id = Double(cores[i].idle &- lastCPU[i].idle)
                let ni = Double(cores[i].nice &- lastCPU[i].nice)
                let busy = u + sy + ni
                let all = busy + id
                perCore.append(all > 0 ? (busy / all).clamped(0, 1) : 0)
                totalBusy += busy
                totalAll += all
            }
            c.perCore = perCore
            c.usage = totalAll > 0 ? (totalBusy / totalAll).clamped(0, 1) : 0
        }
        lastCPU = cores

        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) > 0 { c.load1 = loads[0] }
        return c
    }

    // MARK: 磁盘

    private func sampleDisk() -> DiskSnapshot {
        var d = DiskSnapshot()
        var st = statfs()
        if statfs("/", &st) == 0 {
            d.total = Int64(st.f_blocks) * Int64(st.f_bsize)
            d.free = Int64(st.f_bavail) * Int64(st.f_bsize)
        }
        return d
    }

    // MARK: 网络

    private func sampleNetwork(dt: TimeInterval) -> NetworkSnapshot {
        var n = NetworkSnapshot()
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return n }
        defer { freeifaddrs(ifaddr) }

        var down: Int64 = 0
        var up: Int64 = 0
        var ptr = ifaddr
        while let p = ptr {
            let flags = Int32(p.pointee.ifa_flags)
            if let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
               (flags & IFF_LOOPBACK) == 0, let data = p.pointee.ifa_data {
                let name = String(cString: p.pointee.ifa_name)
                // 排除虚拟接口，避免 VPN 流量重复计数
                if !name.hasPrefix("awdl"), !name.hasPrefix("llw"), !name.hasPrefix("utun"),
                   !name.hasPrefix("gif"), !name.hasPrefix("stf"), !name.hasPrefix("bridge"),
                   !name.hasPrefix("lo") {
                    let d = data.assumingMemoryBound(to: if_data.self).pointee
                    down &+= Int64(d.ifi_ibytes)
                    up &+= Int64(d.ifi_obytes)
                }
            }
            ptr = p.pointee.ifa_next
        }

        n.totalDown = down
        n.totalUp = up
        if lastNet.down > 0 {
            n.downPerSec = max(0, Double(down - lastNet.down) / dt)
            n.upPerSec = max(0, Double(up - lastNet.up) / dt)
        }
        lastNet = (down, up)
        return n
    }

    // MARK: 电池

    private func sampleBattery() -> BatterySnapshot {
        var b = BatterySnapshot()
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return b
        }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            if let type = desc[kIOPSTypeKey as String] as? String, type == kIOPSInternalBatteryType as String {
                b.present = true
                b.percentage = desc[kIOPSCurrentCapacityKey as String] as? Int ?? 0
                let state = desc[kIOPSPowerSourceStateKey as String] as? String
                b.charging = (state == (kIOPSACPowerValue as String))
                b.condition = desc[kIOPSBatteryHealthKey as String] as? String ?? ""
                if let cycles = smartBatteryCycleCount() { b.cycleCount = cycles }
                break
            }
        }
        return b
    }

    private func smartBatteryCycleCount() -> Int? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var prop: Unmanaged<CFMutableDictionary>?
        if IORegistryEntryCreateCFProperties(service, &prop, kCFAllocatorDefault, 0) == KERN_SUCCESS,
           let dict = prop?.takeRetainedValue() as? [String: Any],
           let cycles = dict["CycleCount"] as? Int {
            return cycles
        }
        return nil
    }
}

// MARK: - 温度（Apple Silicon，免 root，走私有 IOHID 接口）

private typealias IOHIDCreateFn    = @convention(c) (CFAllocator?) -> CFTypeRef?
private typealias IOHIDSetMatchFn  = @convention(c) (CFTypeRef, CFDictionary?) -> Void
private typealias IOHIDCopySvcFn   = @convention(c) (CFTypeRef) -> CFArray?
private typealias IOHIDCopyPropFn  = @convention(c) (CFTypeRef, CFString) -> CFTypeRef?
private typealias IOHIDCopyEventFn = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> CFTypeRef?
private typealias IOHIDGetFloatFn  = @convention(c) (CFTypeRef, Int32) -> Double

final class TemperatureReader {
    static let shared = TemperatureReader()

    private var create: IOHIDCreateFn?
    private var setMatching: IOHIDSetMatchFn?
    private var copyServices: IOHIDCopySvcFn?
    private var copyProperty: IOHIDCopyPropFn?
    private var copyEvent: IOHIDCopyEventFn?
    private var getFloat: IOHIDGetFloatFn?
    private var client: CFTypeRef?
    private let lock = NSLock()

    private let eventType: Int64 = 15
    private let field: Int32 = 0xf0000

    private init() {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return }
        func sym<T>(_ n: String, _ t: T.Type) -> T? {
            guard let p = dlsym(h, n) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        create       = sym("IOHIDEventSystemClientCreate", IOHIDCreateFn.self)
        setMatching  = sym("IOHIDEventSystemClientSetMatching", IOHIDSetMatchFn.self)
        copyServices = sym("IOHIDEventSystemClientCopyServices", IOHIDCopySvcFn.self)
        copyProperty = sym("IOHIDServiceClientCopyProperty", IOHIDCopyPropFn.self)
        copyEvent    = sym("IOHIDServiceClientCopyEvent", IOHIDCopyEventFn.self)
        getFloat     = sym("IOHIDEventGetFloatValue", IOHIDGetFloatFn.self)
        if let create { client = create(kCFAllocatorDefault) }
    }

    var isAvailable: Bool { client != nil && copyServices != nil }

    func read() -> TemperatureSnapshot {
        var snap = TemperatureSnapshot()
        guard isAvailable else { return snap }
        lock.lock(); defer { lock.unlock() }

        guard let client, let setMatching, let copyServices,
              let copyProperty, let copyEvent, let getFloat else { return snap }

        setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        guard let arr = copyServices(client) else { return snap }

        var cpuCandidates: [Double] = []
        for i in 0..<CFArrayGetCount(arr) {
            let svc = unsafeBitCast(CFArrayGetValueAtIndex(arr, i), to: CFTypeRef.self)
            let name = (copyProperty(svc, "Product" as CFString) as? String) ?? ""
            guard !name.isEmpty, let ev = copyEvent(svc, eventType, 0, 0) else { continue }
            let v = getFloat(ev, field)
            guard v > 0, v < 130 else { continue }
            snap.sensorCount += 1
            if snap.hottest == nil || v > snap.hottest!.value { snap.hottest = (name, v) }

            let lower = name.lowercased()
            if (lower.contains("tdie") && !lower.contains("tcal"))
                || lower.contains("soc mtr temp") || lower.contains("pmgr soc die temp") {
                cpuCandidates.append(v)
            } else if lower.contains("gpu mtr") {
                snap.gpu = Swift.max(snap.gpu ?? 0, v)
            } else if lower.contains("nand") {
                snap.ssd = Swift.max(snap.ssd ?? 0, v)
            } else if lower.contains("gas gauge battery") {
                snap.battery = Swift.max(snap.battery ?? 0, v)
            }
        }
        snap.cpu = cpuCandidates.max()
        return snap
    }
}
