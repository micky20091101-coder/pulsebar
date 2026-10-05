import AppKit
import CoreGraphics
import Foundation

// 用法: makeicon <输出目录(iconset)>
// 直接按目标像素尺寸渲染，避免缩放导致的模糊

let args = CommandLine.arguments
guard args.count >= 2 else { fputs("用法: makeicon <iconset目录>\n", stderr); exit(1) }
let outDir = args[1]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> CGImage? {
    let s = Int(size)
    guard let ctx = CGContext(data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let inset = size * 0.08
    let body = rect.insetBy(dx: inset, dy: inset)
    let radius = size * 0.22

    // 背景：深色圆角矩形 + 轻微渐变
    let bgPath = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let colors = [
        CGColor(red: 0.16, green: 0.18, blue: 0.24, alpha: 1),
        CGColor(red: 0.08, green: 0.09, blue: 0.13, alpha: 1),
    ] as CFArray
    if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
    }
    ctx.restoreGState()

    // 外描边
    ctx.addPath(bgPath)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.10))
    ctx.setLineWidth(max(1, size * 0.01))
    ctx.strokePath()

    // 表盘圆弧（270°）
    let center = CGPoint(x: size / 2, y: size / 2)
    let arcRadius = size * 0.30
    let startAngle = CGFloat.pi * 0.75
    let endAngle = CGFloat.pi * 2.25
    ctx.setLineCap(.round)
    ctx.setLineWidth(size * 0.09)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.14))
    ctx.addArc(center: center, radius: arcRadius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
    ctx.strokePath()

    // 已用部分（约 62%）用绿色
    let usedEnd = startAngle + (endAngle - startAngle) * 0.62
    ctx.setStrokeColor(CGColor(red: 0.30, green: 0.80, blue: 0.48, alpha: 1))
    ctx.addArc(center: center, radius: arcRadius, startAngle: startAngle, endAngle: usedEnd, clockwise: false)
    ctx.strokePath()

    // 指针
    let needleAngle = usedEnd
    let needleLen = arcRadius * 0.72
    let tip = CGPoint(x: center.x + cos(needleAngle) * needleLen,
                      y: center.y + sin(needleAngle) * needleLen)
    ctx.setStrokeColor(CGColor(red: 0.98, green: 0.98, blue: 1.0, alpha: 1))
    ctx.setLineWidth(size * 0.045)
    ctx.setLineCap(.round)
    ctx.move(to: center)
    ctx.addLine(to: tip)
    ctx.strokePath()

    // 中心圆点
    ctx.setFillColor(CGColor(red: 0.98, green: 0.98, blue: 1.0, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: center.x - size * 0.045, y: center.y - size * 0.045,
                               width: size * 0.09, height: size * 0.09))

    return ctx.makeImage()
}

let variants: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for (name, size) in variants {
    guard let cg = drawIcon(size: size) else { fputs("渲染失败 \(name)\n", stderr); exit(1) }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    try? data.write(to: url)
}
print("图标已生成到 \(outDir)")
