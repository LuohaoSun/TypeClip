// 生成 AppIcon: 蓝色渐变圆角方块 + 白色键盘符号(简约). 用法: swift GenIcon.swift && iconutil ...
import AppKit

let master: NSImage = {
    let size: CGFloat = 1024
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let inset: CGFloat = 44
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: 232, yRadius: 232)
    let gradient = NSGradient(
        starting: NSColor(srgbRed: 0.32, green: 0.53, blue: 0.96, alpha: 1),
        ending: NSColor(srgbRed: 0.15, green: 0.34, blue: 0.86, alpha: 1)
    )!
    gradient.draw(in: path, angle: -90)

    if let base = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil),
       let sized = base.withSymbolConfiguration(.init(pointSize: 540, weight: .regular)) {
        let tinted = NSImage(size: sized.size)
        tinted.lockFocus()
        sized.draw(in: NSRect(origin: .zero, size: sized.size))
        NSColor.white.set()
        NSRect(origin: .zero, size: sized.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.draw(in: NSRect(
            x: (size - sized.size.width) / 2,
            y: (size - sized.size.height) / 2 - 10,
            width: sized.size.width,
            height: sized.size.height
        ))
    }

    image.unlockFocus()
    return image
}()

func pngData(_ image: NSImage, pixels: CGFloat) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(pixels), pixelsHigh: Int(pixels),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

let fm = FileManager.default
try? fm.removeItem(atPath: "build/icon.iconset")
try! fm.createDirectory(atPath: "build/icon.iconset", withIntermediateDirectories: true)
for (name, px) in sizes {
    try! pngData(master, pixels: px).write(to: URL(fileURLWithPath: "build/icon.iconset/\(name)"))
}
print("iconset written")
