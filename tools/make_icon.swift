// Draws the Macap icon and writes Resources/AppIcon.icns.
// Run from the repo root: swift tools/make_icon.swift
import AppKit

/// Same geometry as the inline SVG in the UI prototypes (viewBox 256, y down).
func drawIcon(_ ctx: CGContext, size: CGFloat) {
    let k = size / 256
    ctx.saveGState()
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: k, y: -k)
    ctx.setFillColor(CGColor(srgbRed: 0xef / 255, green: 0xeb / 255, blue: 0xe2 / 255, alpha: 1))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 24, y: 24, width: 208, height: 208), cornerWidth: 48, cornerHeight: 48, transform: nil))
    ctx.fillPath()
    ctx.setStrokeColor(CGColor(srgbRed: 0x1b / 255, green: 0x1a / 255, blue: 0x17 / 255, alpha: 1))
    ctx.setLineWidth(6)
    ctx.stroke(CGRect(x: 52, y: 62, width: 100, height: 74))
    ctx.stroke(CGRect(x: 104, y: 120, width: 100, height: 74))
    ctx.setFillColor(CGColor(srgbRed: 0xbf / 255, green: 0x33 / 255, blue: 0x20 / 255, alpha: 1))
    ctx.fill(CGRect(x: 78, y: 91, width: 100, height: 74))
    ctx.restoreGState()
}

func writePNG(px: Int, to url: URL) throws {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
    drawIcon(ctx, size: CGFloat(px))
    let data = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
    try data.write(to: url)
}

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon-\(getpid()).iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    try writePNG(px: pt, to: iconset.appendingPathComponent("icon_\(pt)x\(pt).png"))
    try writePNG(px: pt * 2, to: iconset.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
try? fm.removeItem(at: iconset)
guard p.terminationStatus == 0 else { fatalError("iconutil failed: \(p.terminationStatus)") }
print("wrote \(out.path)")
