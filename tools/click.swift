import CoreGraphics
import Foundation

// 在屏幕坐标 (x, y) 点一下鼠标左键（用于验证交互，比如分页切换）
// 用法: click <x> <y> [次数]

let a = CommandLine.arguments
let x = Double(a.count > 1 ? a[1] : "0") ?? 0
let y = Double(a.count > 2 ? a[2] : "0") ?? 0
let times = Int(a.count > 3 ? a[3] : "1") ?? 1

guard let src = CGEventSource(stateID: .hidSystemState) else { exit(1) }
let pt = CGPoint(x: x, y: y)

// 先把光标移过去（很多控件需要 hover 才响应）
CGWarpMouseCursorPosition(pt)
usleep(250_000)

for _ in 0..<times {
    guard let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
                             mouseCursorPosition: pt, mouseButton: .left),
          let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
                           mouseCursorPosition: pt, mouseButton: .left) else { exit(1) }
    down.post(tap: .cghidEventTap)
    usleep(60_000)
    up.post(tap: .cghidEventTap)
    usleep(250_000)
}
print("已点击 (\(Int(x)), \(Int(y))) \(times) 次")
