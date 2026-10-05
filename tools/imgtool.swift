import AppKit
import CoreGraphics
import Foundation

// 用法:
//   imgtool crop <in> <out> <x> <y> <w> <h>     # 坐标以左上角为原点
//   imgtool diff <a> <b> <y0> <y1>             # 打印 y0..y1 行内像素差异的包围盒

let a = CommandLine.arguments

func load(_ path: String) -> CGImage? {
    guard let img = NSImage(contentsOfFile: path),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    return cg
}

func pixels(_ cg: CGImage) -> [UInt8]? {
    let w = cg.width, h = cg.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return buf
}

guard a.count >= 2 else { fputs("需要子命令\n", stderr); exit(1) }

switch a[1] {
case "crop":
    guard a.count >= 8, let x = Int(a[4]), let y = Int(a[5]), let w = Int(a[6]), let h = Int(a[7]),
          let cg = load(a[2]) else { fputs("参数错误\n", stderr); exit(1) }
    guard let cropped = cg.cropping(to: CGRect(x: x, y: y, width: w, height: h)) else {
        fputs("裁剪失败\n", stderr); exit(1)
    }
    let rep = NSBitmapImageRep(cgImage: cropped)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: a[3]))
    print("裁剪完成 \(w)x\(h) -> \(a[3])")

case "diff":
    guard a.count >= 6, let y0 = Int(a[4]), let y1 = Int(a[5]),
          let cgA = load(a[2]), let cgB = load(a[3]),
          cgA.width == cgB.width, cgA.height == cgB.height,
          let pa = pixels(cgA), let pb = pixels(cgB) else { fputs("参数错误\n", stderr); exit(1) }
    let w = cgA.width, h = cgA.height
    var minX = w, maxX = -1, minY = h, maxY = -1
    var count = 0
    for y in max(0, y0)..<min(h, y1) {
        for x in 0..<w {
            let i = (y * w + x) * 4
            let d = abs(Int(pa[i]) - Int(pb[i])) + abs(Int(pa[i+1]) - Int(pb[i+1])) + abs(Int(pa[i+2]) - Int(pb[i+2]))
            if d > 40 {
                count += 1
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
    }
    if maxX < 0 {
        print("区域 y=\(y0)..\(y1) 内两图无差异（说明该区域没有变化）")
    } else {
        print("差异像素 \(count) 个，包围盒: x=\(minX) y=\(minY) w=\(maxX - minX + 1) h=\(maxY - minY + 1)")
    }

default:
    fputs("未知子命令\n", stderr); exit(1)
}
