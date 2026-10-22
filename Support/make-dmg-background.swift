import AppKit
import Foundation

/// 生成 DMG 引导窗口的背景图。
///
/// 存在意义: 让"把 .app 拖进「应用程序」"这件事在窗口里一眼可见, 并且顺手把
/// 两个最容易卡住同事的信息写在图上 —— 首次打开要右键「打开」(未公证 + quarantine),
/// 以及本包只支持 Apple 芯片。这些从 DMG 内容本身看不出来。
///
/// 用法: make-dmg-background <输出.png> <宽> <高> [scale]
/// 输出是 scale 倍的位图并把 DPI 设成 72*scale, 这样 Finder 按点绘制时不会放大。

let args = CommandLine.arguments
guard args.count >= 4,
      let pointWidth = Double(args[2]), let pointHeight = Double(args[3]) else {
    FileHandle.standardError.write("用法: make-dmg-background <out.png> <宽pt> <高pt> [scale]\n".data(using: .utf8)!)
    exit(2)
}
let outPath = args[1]
let scale = args.count > 4 ? (Double(args[4]) ?? 2) : 2

_ = NSApplication.shared  // 离屏绘制也先建一下, 免得字体/图像子系统没初始化

let pw = Int(pointWidth * scale), ph = Int(pointHeight * scale)
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { exit(3) }
rep.size = NSSize(width: pointWidth, height: pointHeight)

guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { exit(3) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx

let W = CGFloat(pointWidth), H = CGFloat(pointHeight)

// 背景: 上浅下更浅的竖向渐变, 和系统浅色外观接近
let gradient = NSGradient(colors: [
    NSColor(calibratedWhite: 0.965, alpha: 1),
    NSColor(calibratedWhite: 0.995, alpha: 1),
])!
gradient.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

func centered(_ text: String, y: CGFloat, font: NSFont, color: NSColor) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let s = NSAttributedString(string: text, attributes: attrs)
    let size = s.size()
    s.draw(at: NSPoint(x: (W - size.width) / 2, y: y))
}

// 文字统一按图片宽度居中: 无侧边栏时(实测的常见情形)正好居中; 有侧边栏时内容区被压窄,
// 可能略偏, 但仍在可视范围内。文字全部放在上半部 —— 底部留空是因为实测 Finder 给的窗口
// 内容区高度可能比这张图矮(实测 920x436 的窗口, 内容区约 374pt), 图片按左上角对齐后底部会被裁。
centered("安装 TypeClip", y: H - 56, font: .systemFont(ofSize: 24, weight: .semibold),
         color: NSColor(calibratedWhite: 0.12, alpha: 1))
centered("把左边的 TypeClip 拖到右边的「应用程序」文件夹", y: H - 81,
         font: .systemFont(ofSize: 14), color: NSColor(calibratedWhite: 0.38, alpha: 1))

let warn = NSColor(calibratedRed: 0.72, green: 0.33, blue: 0.05, alpha: 1)
let note = NSColor(calibratedWhite: 0.50, alpha: 1)
centered("需要 macOS 13 或更高版本 · 仅支持 Apple 芯片 (arm64)", y: H - 108,
         font: .systemFont(ofSize: 12), color: note)
centered("首次打开若提示「无法验证开发者」: 右键点 TypeClip → 打开", y: H - 128,
         font: .systemFont(ofSize: 12), color: warn)
centered("装好后在 系统设置 → 隐私与安全性 → 辅助功能 里勾选 TypeClip", y: H - 148,
         font: .systemFont(ofSize: 12), color: warn)

// 两个图标之间的箭头。图标中心 (125, 220) 与 (405, 220)(自图片顶部计), 图标 128pt 宽。
// y 取 220 而不是更靠下: 实测 Finder 内容区只有 ~374pt 高, 且图标实际落点比设计值低约 18pt,
// 留够 128pt 图标 + 下方标签的位置, 否则标签会被裁掉。
// 两个图标刻意都放在左侧 530pt 内: 有侧边栏时内容区可能只剩 ~600pt, 右边那个仍要能看见。
let arrowY: CGFloat = H - 220
let startX: CGFloat = 125 + 64 + 20
let endX: CGFloat = 405 - 64 - 20
let accent = NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.85, alpha: 0.75)
accent.setStroke()
accent.setFill()

let shaft = NSBezierPath()
shaft.lineWidth = 5
shaft.lineCapStyle = .round
shaft.move(to: NSPoint(x: startX, y: arrowY))
shaft.line(to: NSPoint(x: endX - 16, y: arrowY))
shaft.stroke()

let head = NSBezierPath()
head.move(to: NSPoint(x: endX, y: arrowY))
head.line(to: NSPoint(x: endX - 22, y: arrowY + 13))
head.line(to: NSPoint(x: endX - 22, y: arrowY - 13))
head.close()
head.fill()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(4) }
try png.write(to: URL(fileURLWithPath: outPath))

// 把 DPI 写成 72*scale, Finder 才会按点(而不是像素)铺背景图。
let dpi = Int(72 * scale)
let sips = Process()
sips.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
sips.arguments = ["-s", "dpiWidth", "\(dpi)", "-s", "dpiHeight", "\(dpi)", outPath]
try? sips.run()
sips.waitUntilExit()

print("背景图: \(outPath) (\(pw)x\(ph) px @ \(dpi) dpi = \(Int(pointWidth))x\(Int(pointHeight)) pt)")
