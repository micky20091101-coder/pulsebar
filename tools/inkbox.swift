import AppKit
// 量一个区域里「墨迹」的包围盒（用于比对菜单栏文字/图标的高度）
// 用法: inkbox <png> <x> <y> <w> <h>
let a = CommandLine.arguments
let x0 = Int(a[2])!, y0 = Int(a[3])!, w = Int(a[4])!, h = Int(a[5])!
guard let img = NSImage(contentsOfFile: a[1]),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let c = cg.cropping(to: CGRect(x: x0, y: y0, width: w, height: h)) else { exit(1) }
let W = c.width, H = c.height
var buf = [UInt8](repeating: 0, count: W*H*4)
let ctx = CGContext(data: &buf, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W*4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(c, in: CGRect(x:0,y:0,width:W,height:H))
// 背景取区域边缘的平均亮度，找出明显偏离背景的像素
func lum(_ x:Int,_ y:Int)->Double{ let i=(y*W+x)*4; return Double(Int(buf[i])+Int(buf[i+1])+Int(buf[i+2]))/3 }
var bg = 0.0; var n = 0.0
for x in 0..<W { bg += lum(x,0) + lum(x,H-1); n += 2 }
for y in 0..<H { bg += lum(0,y) + lum(W-1,y); n += 2 }
bg /= n
var minX = W, maxX = -1, minY = H, maxY = -1, ink = 0
for y in 0..<H { for x in 0..<W {
    if abs(lum(x,y) - bg) > 55 {
        ink += 1
        if x < minX { minX = x }; if x > maxX { maxX = x }
        if y < minY { minY = y }; if y > maxY { maxY = y }
    }
}}
if ink < 8 { print("(几乎没有墨迹)") ; exit(0) }
print("墨迹: 高 \(maxY-minY+1)px  宽 \(maxX-minX+1)px  顶部y=\(y0+minY)  底部y=\(y0+maxY)  像素数\(ink)")
