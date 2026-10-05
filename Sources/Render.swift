import AppKit
import SwiftUI

/// 离屏渲染：把面板画成 PNG，用来在没有录屏权限的情况下自查布局。
/// 用法：PulseBar --render out.png [--settings] [--demo]
enum RenderMode {
    static func run(output: String, settings: Bool = false, demo: Bool = false) {
        let model = AppModel()
        if demo {
            model.applyDemoData()          // 官网截图用虚构的「普通用户」数据
        } else {
            model.tick()
            model.tick()      // 采两次，让增量型指标（网络/CPU）有值
        }
        model.showSettings = settings

        // 宽度必须跟随设置，否则测不出「面板宽度」这个选项的效果
        let width: CGFloat = CGFloat(model.settings.panelWidth) + 24
        let hosting = NSHostingView(rootView: PanelView(model: model, renderMode: true))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 600)

        let window = NSWindow(contentRect: hosting.frame,
                              styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        let fit = hosting.fittingSize
        let h = max(240, min(fit.height, 1400))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: h)
        window.setContentSize(hosting.frame.size)
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(width * scale),
                                         pixelsHigh: Int(h * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else {
            FileHandle.standardError.write("render: 无法创建位图\n".data(using: .utf8)!)
            exit(1)
        }
        rep.size = hosting.bounds.size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write("render: 无法编码 PNG\n".data(using: .utf8)!)
            exit(1)
        }
        try? data.write(to: URL(fileURLWithPath: output))
        print("已渲染: \(output) (\(Int(width))x\(Int(h)))")
    }
}
