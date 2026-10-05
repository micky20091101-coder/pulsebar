import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

// 生成二维码 PNG
// 用法: qrgen <输出.png> <内容> [边长像素，默认 720]

let a = CommandLine.arguments
guard a.count >= 3 else {
    print("用法: qrgen <out.png> <content> [size]")
    exit(1)
}
let out = a[1]
let content = a[2]
let side = a.count > 3 ? (Int(a[3]) ?? 720) : 720

let filter = CIFilter.qrCodeGenerator()
filter.message = Data(content.utf8)
filter.correctionLevel = "H"

guard let ci = filter.outputImage else {
    print("二维码生成失败")
    exit(1)
}

// 放大到目标尺寸（QR 原图很小）
let scale = CGFloat(side) / ci.extent.width
let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

// 铺白底，保证扫码对比度
let white = CIImage(color: .white).cropped(to: scaled.extent)
let composed = scaled.composited(over: white)

let ctx = CIContext()
guard let cg = ctx.createCGImage(composed, from: composed.extent) else {
    print("渲染失败")
    exit(1)
}

let rep = NSBitmapImageRep(cgImage: cg)
if let png = rep.representation(using: .png, properties: [:]) {
    try? png.write(to: URL(fileURLWithPath: out))
    print("已生成 \(out)  \(cg.width)x\(cg.height)")
} else {
    print("编码失败")
    exit(1)
}
