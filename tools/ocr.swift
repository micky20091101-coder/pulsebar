import AppKit
import Vision
import Foundation

// 用法: ocr <图片> [x y w h]
// 用系统 Vision 框架做文字识别，打印识别结果及其位置（左上角原点像素坐标）。
// 用来"看"截图里到底有没有我们要的菜单栏文字。

let args = CommandLine.arguments
guard args.count >= 2 else { fputs("用法: ocr <图片> [x y w h]\n", stderr); exit(1) }
let path = args[1]

guard let img = NSImage(contentsOfFile: path),
      var cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("无法读取图片\n", stderr); exit(1)
}

var cropX = 0, cropY = 0
if args.count >= 6, let x = Int(args[2]), let y = Int(args[3]), let w = Int(args[4]), let h = Int(args[5]) {
    guard let c = cg.cropping(to: CGRect(x: x, y: y, width: w, height: h)) else {
        fputs("裁剪失败\n", stderr); exit(1)
    }
    cg = c
    cropX = x; cropY = y
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = true
request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

let handler = VNImageRequestHandler(cgImage: cg, options: [:])
do { try handler.perform([request]) } catch { fputs("识别失败: \(error)\n", stderr); exit(1) }

guard let obs = request.results else { print("(无结果)"); exit(0) }

if obs.isEmpty { print("(没有识别到任何文字)") }

for o in obs {
    guard let top = o.topCandidates(1).first else { continue }
    let b = o.boundingBox  // 归一化，左下角原点
    let w = cg.width, h = cg.height
    let px = Int(b.minX * Double(w)) + cropX
    let py = Int((1 - b.maxY) * Double(h)) + cropY
    let pw = Int(b.width * Double(w))
    let ph = Int(b.height * Double(h))
    print(String(format: "x=%4d y=%3d w=%3d h=%3d  置信度%.2f  「%@」",
                 px, py, pw, ph, top.confidence, top.string))
}
