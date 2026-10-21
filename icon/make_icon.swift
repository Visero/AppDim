import Cocoa

// AppDim 图标生成：macOS 现代风格（连续圆角 squircle + SF Symbol 半明半暗圆）
// 用法: swiftc make_icon.swift -o make_icon -framework AppKit && ./make_icon

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppDim.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

/// 连续圆角路径（近似 Apple squircle，圆角半径 22.37%）
func squirclePath(_ rect: NSRect) -> NSBezierPath {
    let r = rect.width * 0.2237
    let path = NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
    return path
}

func tintedSymbol(_ name: String, size: NSSize, color: NSColor) -> NSImage {
    guard let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
        fatalError("SF Symbol not found: \(name)")
    }
    sym.isTemplate = true
    let out = NSImage(size: size)
    out.lockFocus()
    color.set()
    sym.draw(in: NSRect(origin: .zero, size: size),
             from: .zero, operation: .sourceOver, fraction: 1.0)
    NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
    out.unlockFocus()
    return out
}

func render(size: CGFloat, scale: CGFloat) -> NSImage {
    let px = size * scale
    let img = NSImage(size: NSSize(width: px, height: px))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { img.unlockFocus(); return img }

    let bounds = NSRect(x: 0, y: 0, width: px, height: px)

    // 背景：平滑纵向渐变 深夜靛蓝 → 深海军蓝，外加左上径向柔光
    ctx.saveGState()
    squirclePath(bounds).addClip()

    let grad = NSGradient(
        starting: NSColor(red: 0.27, green: 0.33, blue: 0.49, alpha: 1),
        ending: NSColor(red: 0.06, green: 0.08, blue: 0.16, alpha: 1)
    )
    grad?.draw(in: bounds, angle: 270)

    let sheen = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor.white.withAlphaComponent(0.12).cgColor,
            NSColor.clear.cgColor
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawRadialGradient(
        sheen,
        startCenter: CGPoint(x: px * 0.18, y: px * 0.86),
        startRadius: 0,
        endCenter: CGPoint(x: px * 0.18, y: px * 0.86),
        endRadius: px * 0.95,
        options: []
    )
    ctx.restoreGState()

    // 中央 SF Symbol：左亮右暗的半圆，呼应“变暗”
    let glyphSize = px * 0.56
    let glyphRect = NSRect(
        x: (px - glyphSize) / 2,
        y: (px - glyphSize) / 2,
        width: glyphSize,
        height: glyphSize
    )
    let glyph = tintedSymbol("circle.lefthalf.filled",
                             size: NSSize(width: glyphSize, height: glyphSize),
                             color: NSColor(red: 0.91, green: 0.94, blue: 1.0, alpha: 1))
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -px * 0.015),
                  blur: px * 0.03,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    glyph.draw(in: glyphRect)
    ctx.restoreGState()

    img.unlockFocus()
    return img
}

func save(_ image: NSImage, name: String, scale: CGFloat, pointSize: CGFloat) {
    // 以 pointSize 渲染，scale 倍像素输出
    let rendered = render(size: pointSize, scale: scale)
    guard let tiff = rendered.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    try? png.write(to: url)
}

// iconutil 标准清单
let entries: [(name: String, point: CGFloat, scale: CGFloat)] = [
    ("icon_16x16.png", 16, 1),
    ("icon_16x16@2x.png", 16, 2),
    ("icon_32x32.png", 32, 1),
    ("icon_32x32@2x.png", 32, 2),
    ("icon_128x128.png", 128, 1),
    ("icon_128x128@2x.png", 128, 2),
    ("icon_256x256.png", 256, 1),
    ("icon_256x256@2x.png", 256, 2),
    ("icon_512x512.png", 512, 1),
    ("icon_512x512@2x.png", 512, 2),
]
for e in entries {
    save(render(size: e.point, scale: e.scale), name: e.name, scale: e.scale, pointSize: e.point)
}
print("iconset written to \(outDir)")
