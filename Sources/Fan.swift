import Foundation
import IOKit

// MARK: - 风扇读取（AppleSMC）
//
// 说明：MacBook Air 全系无风扇；MacBook Pro / Mac mini / Mac Studio / iMac / Mac Pro 有风扇。
// 这里用经典 AppleSMC 协议读「FNum」拿到风扇数量，再逐个读「F0Ac/F1Ac…」拿转速。
// 读不到就当作无风扇，界面自动隐藏风扇区域 —— 不同机型自动适配。

struct FanSnapshot: Identifiable {
    let id: Int          // 风扇序号
    var rpm: Int         // 当前转速
    var minRPM: Int?     // 最低转速（可读到时）
    var maxRPM: Int?     // 最高转速（可读到时）

    var label: String { id == 0 ? "风扇" : "风扇 \(id + 1)" }
}

final class FanReader {
    static let shared = FanReader()

    private var conn: io_connect_t = 0
    private var opened = false
    private var didTryOpen = false

    private init() {}

    private func ensureOpen() -> Bool {
        if didTryOpen { return opened }
        didTryOpen = true

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }

        var c: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &c) == KERN_SUCCESS, c != 0 else { return false }
        conn = c
        opened = true
        return true
    }

    func close() {
        if opened { IOServiceClose(conn); opened = false }
    }

    var isAvailable: Bool { ensureOpen() }

    // MARK: 底层调用
    //
    // SMCKeyData_t 在 C 里是 80 字节，字段偏移固定：
    //   key@0  vers@4  pLimitData@12  keyInfo.dataSize@28  keyInfo.dataType@32
    //   keyInfo.dataAttributes@36  result@40  status@41  data8@42  data32@44  bytes@48(32)
    // 直接按偏移读写原始缓冲区，避免 Swift 结构体内存布局不确定带来的越界崩溃。

    private let structSize = 80
    private let offKey = 0
    private let offDataSize = 28
    private let offDataType = 32
    private let offData8 = 42
    private let offBytes = 48

    private let cmdReadBytes: UInt8 = 5
    private let cmdReadKeyInfo: UInt8 = 9

    private func fourCC(_ s: String) -> UInt32 {
        var v: UInt32 = 0
        for b in Array(s.utf8.prefix(4)) { v = (v << 8) | UInt32(b) }
        return v
    }

    private func call(_ input: inout [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: structSize)
        var outSize = structSize
        let kr = input.withUnsafeMutableBytes { inBuf -> kern_return_t in
            guard let inPtr = inBuf.baseAddress else { return kIOReturnError }
            return output.withUnsafeMutableBytes { outBuf -> kern_return_t in
                guard let outPtr = outBuf.baseAddress else { return kIOReturnError }
                return IOConnectCallStructMethod(conn, 2, inPtr, structSize, outPtr, &outSize)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return output
    }

    private func readKeyInfo(_ key: String) -> (size: UInt32, type: String)? {
        var input = [UInt8](repeating: 0, count: structSize)
        let k = fourCC(key)
        input[0] = UInt8(k & 0xff); input[1] = UInt8((k >> 8) & 0xff)
        input[2] = UInt8((k >> 16) & 0xff); input[3] = UInt8((k >> 24) & 0xff)
        input[offData8] = cmdReadKeyInfo

        guard let out = call(&input) else { return nil }
        let size = UInt32(out[offDataSize]) | (UInt32(out[offDataSize + 1]) << 8)
            | (UInt32(out[offDataSize + 2]) << 16) | (UInt32(out[offDataSize + 3]) << 24)
        let t = UInt32(out[offDataType]) | (UInt32(out[offDataType + 1]) << 8)
            | (UInt32(out[offDataType + 2]) << 16) | (UInt32(out[offDataType + 3]) << 24)
        let typeChars = [UInt8((t >> 24) & 0xff), UInt8((t >> 16) & 0xff),
                         UInt8((t >> 8) & 0xff), UInt8(t & 0xff)].map { Character(UnicodeScalar($0)) }
        return (size, String(typeChars))
    }

    private func readBytes(_ key: String, size: UInt32) -> [UInt8]? {
        var input = [UInt8](repeating: 0, count: structSize)
        let k = fourCC(key)
        input[0] = UInt8(k & 0xff); input[1] = UInt8((k >> 8) & 0xff)
        input[2] = UInt8((k >> 16) & 0xff); input[3] = UInt8((k >> 24) & 0xff)
        input[offDataSize] = UInt8(size & 0xff)
        input[offDataSize + 1] = UInt8((size >> 8) & 0xff)
        input[offDataSize + 2] = UInt8((size >> 16) & 0xff)
        input[offDataSize + 3] = UInt8((size >> 24) & 0xff)
        input[offData8] = cmdReadBytes

        guard let out = call(&input) else { return nil }
        let n = min(Int(size), 32)
        return Array(out[offBytes..<(offBytes + n)])
    }

    /// 把 SMC 原始值按数据类型转成转速
    private func rpm(from bytes: [UInt8], type: String) -> Int? {
        switch type {
        case "fpe2":   // 14.2 定点数
            guard bytes.count >= 2 else { return nil }
            let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Int(raw) / 4
        case "flt ":   // 32 位浮点
            guard bytes.count >= 4 else { return nil }
            let f = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Float.self) }
            return f.isFinite ? Int(f) : nil
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Int((UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
        default:
            guard bytes.count >= 2 else { return nil }
            return Int((UInt16(bytes[0]) << 8) | UInt16(bytes[1])) / 4
        }
    }

    /// 读取全部风扇；无风扇机型返回空数组
    func read() -> [FanSnapshot] {
        guard ensureOpen() else { return [] }

        var count = 0
        if let info = readKeyInfo("FNum"), let b = readBytes("FNum", size: info.size), !b.isEmpty {
            count = Int(b[0])
        }
        guard count > 0, count <= 12 else { return [] }

        var fans: [FanSnapshot] = []
        for i in 0..<count {
            let key = "F\(i)Ac"
            guard let info = readKeyInfo(key), let b = readBytes(key, size: info.size),
                  let now = rpm(from: b, type: info.type), now > 0 else { continue }
            var mn: Int? = nil, mx: Int? = nil
            if let mi = readKeyInfo("F\(i)Mn"), let mb = readBytes("F\(i)Mn", size: mi.size) {
                mn = rpm(from: mb, type: mi.type)
            }
            if let mi = readKeyInfo("F\(i)Mx"), let mb = readBytes("F\(i)Mx", size: mi.size) {
                mx = rpm(from: mb, type: mi.type)
            }
            fans.append(FanSnapshot(id: i, rpm: now, minRPM: mn, maxRPM: mx))
        }
        return fans
    }
}
