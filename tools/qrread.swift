import AppKit
import Vision
import Foundation

// 识别图片里的二维码内容（验证宣发图上的码能不能扫）
// 用法: qrread <图片>

let a = CommandLine.arguments
guard a.count >= 2 else { fputs("用法: qrread <图片>\n", stderr); exit(1) }
guard let img = NSImage(contentsOfFile: a[1]),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("无法读取图片\n", stderr); exit(1)
}

let req = VNDetectBarcodesRequest()
req.symbologies = [.qr]

let handler = VNImageRequestHandler(cgImage: cg, options: [:])
do { try handler.perform([req]) } catch { fputs("识别失败: \(error)\n", stderr); exit(1) }

let results = req.results ?? []
if results.isEmpty { print("(没有识别到二维码)"); exit(0) }
for r in results {
    if let s = r.payloadStringValue {
        print("二维码内容: \(s)")
    } else {
        print("识别到二维码但内容为空")
    }
}
