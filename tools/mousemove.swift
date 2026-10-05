import CoreGraphics
import Foundation
let a = CommandLine.arguments
let x = a.count > 1 ? Double(a[1])! : 5
let y = a.count > 2 ? Double(a[2])! : 2
CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
usleep(300_000)
print("鼠标已移到 (\(x), \(y))")
