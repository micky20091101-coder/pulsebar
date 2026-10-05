import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

// 生成打赏用的占位图（微信 / 支付宝收款码位置）
// 用法: makeqr <输出目录>
// 用户之后把自己的收款码截图覆盖同名文件即可。

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let size = 640

func draw(accent: NSColor, title: String, subtitle: String, hint: String, path: String) {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { img.unlockFocus(); return }

    // 背景
    NSColor(calibratedWhite: 1.0, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()

    // 外框
    accent.setStroke()
    let border = NSBezierPath(roundedRect: NSRect(x: 24, y: 24, width: size - 48, height: size - 48),
                              xRadius: 28, yRadius: 28)
    border.lineWidth = 8
    border.stroke()

    // 顶部标题
    let titleAttr: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 40, weight: .bold),
        .foregroundColor: accent,
    ]
    let titleStr = NSAttributedString(string: title, attributes: titleAttr)
    let titleSize = titleStr.size()
    titleStr.draw(at: NSPoint(x: (CGFloat(size) - titleSize.width) / 2, y: CGFloat(size) - 110))

    // 中间「二维码位置」虚线框
    let qrRect = NSRect(x: 120, y: 150, width: size - 240, height: size - 240)
    let dash = NSBezierPath(roundedRect: qrRect, xRadius: 18, yRadius: 18)
    dash.lineWidth = 3
    dash.setLineDash([10, 8], count: 2, phase: 0)
    NSColor(calibratedWhite: 0.72, alpha: 1).setStroke()
    dash.stroke()

    // 虚线框内文字
    let midAttr: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 26, weight: .semibold),
        .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 1),
    ]
    let mid = NSAttributedString(string: "收款码位置", attributes: midAttr)
    let midSize = mid.size()
    mid.draw(at: NSPoint(x: (CGFloat(size) - midSize.width) / 2, y: CGFloat(size) - 400))

    let subAttr: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 15, weight: .regular),
        .foregroundColor: NSColor(calibratedWhite: 0.55, alpha: 1),
    ]
    let sub = NSAttributedString(string: subtitle, attributes: subAttr)
    let subSize = sub.size()
    sub.draw(at: NSPoint(x: (CGFloat(size) - subSize.width) / 2, y: 300))

    // 底部提示
    let hintAttr: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 16, weight: .medium),
        .foregroundColor: NSColor(calibratedWhite: 0.35, alpha: 1),
    ]
    let hintStr = NSAttributedString(string: hint, attributes: hintAttr)
    let hintSize = hintStr.size()
    hintStr.draw(at: NSPoint(x: (CGFloat(size) - hintSize.width) / 2, y: 70))

    img.unlockFocus()

    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
    print("已生成 \(path)")
}

draw(accent: NSColor(calibratedRed: 0.02, green: 0.70, blue: 0.28, alpha: 1),
     title: "微信打赏",
     subtitle: "把你的微信收款码截图放到这里",
     hint: "替换本文件：donate-wechat.png",
     path: "\(outDir)/donate-wechat.png")

draw(accent: NSColor(calibratedRed: 0.10, green: 0.48, blue: 0.92, alpha: 1),
     title: "支付宝打赏",
     subtitle: "把你的支付宝收款码截图放到这里",
     hint: "替换本文件：donate-alipay.png",
     path: "\(outDir)/donate-alipay.png")
