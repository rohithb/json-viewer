// Renders design option "1b — Tree" into an .iconset. Usage: make-icon <out.iconset>
// Coordinates are in the design's 256-unit canvas (top-left origin), scaled per output size.
import AppKit

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

func draw(_ ctx: CGContext, _ s: CGFloat) {
    let tile = CGRect(x: 25, y: 25, width: 206, height: 206)
    let shape = CGPath(roundedRect: tile, cornerWidth: 46, cornerHeight: 46, transform: nil)

    // Drop shadow: 0 6px 14px rgba(0,0,0,.3). Shadow params are in device pixels, y-up.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * s), blur: 14 * s, color: hex(0x000000, 0.3).cgColor)
    ctx.addPath(shape); ctx.setFillColor(hex(0x18181A).cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [hex(0x2E2E32).cgColor, hex(0x18181A).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.maxY), options: [])

    // Rows (tile-relative): disclosure + key, key/string, selected row, key/bool, key/number.
    func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ c: NSColor) {
        ctx.addPath(CGPath(roundedRect: CGRect(x: tile.minX + x, y: tile.minY + y, width: w, height: 12), cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.setFillColor(c.cgColor); ctx.fillPath()
    }
    ctx.move(to: CGPoint(x: tile.minX + 28, y: tile.minY + 49))
    ctx.addLine(to: CGPoint(x: tile.minX + 42, y: tile.minY + 49))
    ctx.addLine(to: CGPoint(x: tile.minX + 35, y: tile.minY + 59))
    ctx.closePath(); ctx.setFillColor(hex(0x8E8E93).cgColor); ctx.fillPath()
    bar(50, 48, 70, hex(0xD0A8FF))
    bar(48, 69, 40, hex(0xD0A8FF)); bar(96, 69, 60, hex(0xFF8F75))
    ctx.setFillColor(hex(0x007AFF).cgColor); ctx.fill(CGRect(x: tile.minX, y: tile.minY + 90, width: tile.width, height: 26))
    bar(48, 97, 34, .white); bar(90, 97, 44, hex(0xFFFFFF, 0.7))
    bar(48, 125, 52, hex(0xD0A8FF)); bar(108, 125, 28, hex(0xF590C8))
    bar(48, 146, 30, hex(0xD0A8FF)); bar(86, 146, 66, hex(0x7CB8FF))
    ctx.restoreGState()

    // Hairline: inset 0 0 0 1px rgba(255,255,255,.08)
    ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 45.5, cornerHeight: 45.5, transform: nil))
    ctx.setStrokeColor(hex(0xFFFFFF, 0.08).cgColor); ctx.setLineWidth(1); ctx.strokePath()
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let px = pt * scale
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(px)); ctx.scaleBy(x: CGFloat(px) / 256, y: -CGFloat(px) / 256) // top-left origin
    draw(ctx, CGFloat(px) / 256)
    let png = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
    try png.write(to: out.appendingPathComponent("icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"))
}
