import AppKit
import WebKit
import Foundation

// 用 WKWebView 把网页渲染成 PNG（可加载本地 HTML 或线上 URL）
// 用法:
//   shot <输出.png> <宽> <高> <file:///... 或 https://...> [--full]
//   --full: 按整页高度截图（高度参数忽略）

final class Shooter: NSObject, WKNavigationDelegate {
    let web: WKWebView
    let out: String
    let w: CGFloat
    let h: CGFloat
    let fullPage: Bool
    let evalJS: String?
    var done = false

    init(out: String, w: CGFloat, h: CGFloat, fullPage: Bool, evalJS: String?) {
        self.out = out
        self.w = w
        self.h = h
        self.fullPage = fullPage
        self.evalJS = evalJS
        let cfg = WKWebViewConfiguration()
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")
        self.web = WKWebView(frame: NSRect(x: 0, y: 0, width: w, height: h), configuration: cfg)
        super.init()
        self.web.navigationDelegate = self
    }

    func load(_ target: String) {
        if target.hasPrefix("http") {
            web.load(URLRequest(url: URL(string: target)!))
        } else {
            let url = URL(fileURLWithPath: target)
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 等字体/图片/JS 稳定
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self = self else { return }
            if let js = self.evalJS {
                self.web.evaluateJavaScript(js) { _, err in
                    if let err = err { FileHandle.standardError.write("JS 执行出错: \(err)\n".data(using: .utf8)!) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { self.capture() }
                }
            } else {
                self.capture()
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        FileHandle.standardError.write("加载失败: \(error)\n".data(using: .utf8)!)
        NSApp.terminate(nil)
    }

    func capture() {
        let snapshotCfg = WKSnapshotConfiguration()
        if fullPage {
            snapshotCfg.rect = NSRect(x: 0, y: 0, width: w, height: h)
        }
        web.takeSnapshot(with: snapshotCfg) { [weak self] img, err in
            guard let self = self else { return }
            if let err = err {
                FileHandle.standardError.write("截图失败: \(err)\n".data(using: .utf8)!)
                NSApp.terminate(nil)
            }
            guard let img = img,
                  let tiff = img.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                FileHandle.standardError.write("编码失败\n".data(using: .utf8)!)
                NSApp.terminate(nil)
                return
            }
            try? png.write(to: URL(fileURLWithPath: self.out))
            print("已生成 \(self.out)  \(rep.pixelsWide)x\(rep.pixelsHigh)")
            NSApp.terminate(nil)
        }
    }
}

let a = CommandLine.arguments
guard a.count >= 5 else {
    print("用法: shot <out.png> <w> <h> <url|file> [--full]")
    exit(1)
}
let out = a[1]
let w = CGFloat(Double(a[2]) ?? 1200)
let h = CGFloat(Double(a[3]) ?? 900)
let target = a[4]
let full = a.contains("--full")
let jsArg = a.first { $0.hasPrefix("--js=") }.map { String($0.dropFirst(5)) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let shooter = Shooter(out: out, w: w, h: h, fullPage: full, evalJS: jsArg)
shooter.load(target)
app.run()
