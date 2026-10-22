import AppKit

// 生成 macOS 应用图标：圆角矩形渐变底 + 👌 emoji
// 用法: swift scripts/generate-icon.swift   （产物写入 Resources/Assets.xcassets/AppIcon.appiconset/）

let size: CGFloat = 1024
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep) else {
    fatalError("无法创建位图上下文")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

// macOS 图标规范：内容区约占画布 82%，大圆角
let inset = size * 0.09
let contentRect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let cornerRadius = contentRect.width * 0.225
let contentPath = NSBezierPath(roundedRect: contentRect, xRadius: cornerRadius, yRadius: cornerRadius)
contentPath.addClip()

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.16, green: 0.24, blue: 0.42, alpha: 1),
    NSColor(calibratedRed: 0.10, green: 0.55, blue: 0.62, alpha: 1),
])
gradient?.draw(in: contentRect, angle: -60)

// 手势 emoji 主体
let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size * 0.58)]
let emoji = NSAttributedString(string: "👌", attributes: attributes)
let emojiSize = emoji.size()
emoji.draw(at: NSPoint(x: (size - emojiSize.width) / 2, y: (size - emojiSize.height) / 2 - size * 0.02))

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("PNG 编码失败") }
let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let outDir = scriptDir.deletingLastPathComponent()
    .appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
try png.write(to: outDir.appendingPathComponent("icon_1024.png"))

let contentsJSON = """
{
  "images" : [
    {
      "filename" : "icon_1024.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "1024x1024"
    }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
try contentsJSON.write(to: outDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("图标已生成: \(outDir.path)/icon_1024.png")
