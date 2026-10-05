import Foundation
import SwiftUI

// MARK: - 数值格式化

enum Fmt {
    /// 字节 -> 人类可读，如 1.2 GB
    static func bytes(_ value: Int64) -> String {
        let v = Double(max(0, value))
        let units = ["B", "KB", "MB", "GB", "TB"]
        var idx = 0
        var n = v
        while n >= 1024 && idx < units.count - 1 {
            n /= 1024
            idx += 1
        }
        let fmt: String
        if idx == 0 || n >= 100 { fmt = "%.0f" }
        else if n >= 10 { fmt = "%.1f" }
        else { fmt = "%.2f" }
        return String(format: fmt, n) + " " + units[idx]
    }

    /// 网络速率
    static func rate(_ bytesPerSec: Double) -> String {
        if bytesPerSec < 1024 { return String(format: "%.0f B/s", bytesPerSec) }
        if bytesPerSec < 1024 * 1024 { return String(format: "%.0f KB/s", bytesPerSec / 1024) }
        return String(format: "%.1f MB/s", bytesPerSec / 1024 / 1024)
    }

    static func percent(_ v: Double) -> String { String(format: "%.0f%%", v) }
    static func temp(_ v: Double?) -> String { v == nil ? "--" : String(format: "%.0f°", v!) }
    static func one(_ v: Double) -> String { String(format: "%.1f", v) }
}

// MARK: - 颜色 / 等级

enum Level {
    case normal, warning, critical

    var color: Color {
        switch self {
        case .normal: return Color(red: 0.30, green: 0.78, blue: 0.45)
        case .warning: return Color(red: 0.98, green: 0.72, blue: 0.20)
        case .critical: return Color(red: 0.95, green: 0.35, blue: 0.35)
        }
    }

    static func of(_ ratio: Double) -> Level {
        if ratio >= 0.9 { return .critical }
        if ratio >= 0.75 { return .warning }
        return .normal
    }

    static func ofTemp(_ c: Double?) -> Level {
        guard let c else { return .normal }
        if c >= 95 { return .critical }
        if c >= 80 { return .warning }
        return .normal
    }
}

/// 面板里统一的配色（跟随系统明暗）
struct Theme {
    static let card = Color.primary.opacity(0.05)
    static let cardStroke = Color.primary.opacity(0.08)
    static let secondary = Color.secondary
    static let track = Color.primary.opacity(0.12)
}

// MARK: - 小工具

extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(self, lo), hi) }
}

/// 让某个字符串在菜单栏里是等宽的，避免数字跳动时宽度抖动
func mono(_ s: String, size: CGFloat = 12, weight: NSFont.Weight = .medium) -> NSAttributedString {
    NSAttributedString(string: s, attributes: [
        .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor.labelColor,
    ])
}
