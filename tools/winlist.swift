import AppKit
import CoreGraphics
import Foundation

// 用法: winlist
// 列出菜单栏上所有状态栏项窗口（layer == 25）的真实位置，按 x 排序。
// 用来判断「菜单栏是不是满了」以及自己的项被摆到了哪里。

guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] else {
    fputs("无法获取窗口列表\n", stderr); exit(1)
}

struct Item { let owner: String; let x: Double; let w: Double; let y: Double; let h: Double }

var items: [Item] = []
for w in list {
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    guard layer == 25 else { continue }          // 25 = 状态栏层
    let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
    guard let b = w[kCGWindowBounds as String] as? [String: Any] else { continue }
    let x = b["X"] as? Double ?? 0
    let y = b["Y"] as? Double ?? 0
    let ww = b["Width"] as? Double ?? 0
    let hh = b["Height"] as? Double ?? 0
    items.append(Item(owner: owner, x: x, w: ww, y: y, h: hh))
}

items.sort { $0.x < $1.x }

let screenW = NSScreen.main?.frame.width ?? 0
print("主屏宽度: \(Int(screenW))  菜单栏项共 \(items.count) 个")
func pad(_ s: String, _ n: Int) -> String {
    let count = s.count
    return count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - count)
}
print(pad("OWNER", 26) + pad("X", 8) + pad("WIDTH", 8) + pad("Y", 8) + "状态")
for it in items {
    let abnormal = (it.y < 0 || it.x < 0 || it.x + it.w > screenW)
    let line = pad(it.owner, 26)
        + pad(String(Int(it.x)), 8)
        + pad(String(Int(it.w)), 8)
        + pad(String(Int(it.y)), 8)
        + (abnormal ? "⚠️ 离屏/异常" : "正常")
    print(line)
}

// 估算菜单栏剩余空间
if let maxX = items.map({ $0.x + $0.w }).max() {
    print("\n最右侧项结束于 x=\(Int(maxX))，屏幕宽 \(Int(screenW))")
}
