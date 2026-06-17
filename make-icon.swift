// make-icon — 生成 app 图标:深色圆角底 + 居中 🐤,导出 .iconset 所需各尺寸 PNG。
// 用法:swiftc make-icon.swift -o /tmp/makeicon && /tmp/makeicon <输出 iconset 目录>
// 之后由 iconutil 打成 .icns(见 build.sh)。

import Cocoa

// .iconset 规定的文件名 → 像素尺寸
let specs: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write("用法: makeicon <iconset 目录>\n".data(using: .utf8)!)
    exit(1)
}
let outDir = CommandLine.arguments[1]

/// 渲染单个尺寸的图标 PNG:深色斜向渐变圆角方 + 居中 🐤
func renderPNG(_ px: Int) -> Data {
    let size = CGFloat(px)
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let inset = size * 0.085
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let radius = rect.width * 0.2237 // 近似 Big Sur 圆角

    let clip = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    clip.addClip()
    let grad = NSGradient(colors: [
        NSColor(srgbRed: 0.20, green: 0.23, blue: 0.31, alpha: 1), // 顶:石板蓝
        NSColor(srgbRed: 0.11, green: 0.12, blue: 0.17, alpha: 1), // 底:更深
    ])!
    grad.draw(in: rect, angle: -90)

    // 顶部一抹高光,增加质感
    let hi = NSGradient(colors: [
        NSColor(white: 1, alpha: 0.10), NSColor(white: 1, alpha: 0.0),
    ])!
    hi.draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)

    let emoji = "🐤" as NSString
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size * 0.52)]
    let s = emoji.size(withAttributes: attrs)
    emoji.draw(at: NSPoint(x: (size - s.width) / 2, y: (size - s.height) / 2 - size * 0.02),
               withAttributes: attrs)

    image.unlockFocus()
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

for spec in specs {
    let url = URL(fileURLWithPath: outDir).appendingPathComponent("\(spec.name).png")
    try! renderPNG(spec.px).write(to: url)
}
print("图标 PNG 已生成到 \(outDir)")
