// Draws the Encore app icon: a sunset-gradient tile with a bold white play mark and
// a translucent echo of it behind, suggesting motion. Writes a .iconset of PNGs.
// Usage: swiftc scripts/make-icon.swift -o /tmp/make-icon && /tmp/make-icon <out.iconset>
import AppKit

func drawIcon(size s: CGFloat, in ctx: CGContext) {
    let u = s / 1024 // design units
    let space = CGColorSpaceCreateDeviceRGB()
    func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }

    // Tile on the macOS icon grid (824pt square, continuous-looking corners).
    let tile = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185 * u, cornerHeight: 185 * u, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * u), blur: 30 * u, color: color(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0xFF5E62))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    // Diagonal sunset: violet top-left to amber bottom-right.
    let bg = CGGradient(colorsSpace: space,
                        colors: [color(0x5B2BD9), color(0xD9387A), color(0xFF6A3D), color(0xFFB347)] as CFArray,
                        locations: [0, 0.4, 0.75, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
    // Soft light from the top, like glass.
    let sheen = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(sheen, startCenter: CGPoint(x: 400 * u, y: 900 * u), startRadius: 0,
                           endCenter: CGPoint(x: 400 * u, y: 900 * u), endRadius: 620 * u, options: [])
    ctx.restoreGState()

    func playPath(center c: CGPoint, height h: CGFloat, corner: CGFloat) -> CGPath {
        // Optically centred: the triangle's mass sits a little left of its box centre.
        let tri = [CGPoint(x: c.x - h * 0.40, y: c.y + h / 2),
                   CGPoint(x: c.x + h * 0.55, y: c.y),
                   CGPoint(x: c.x - h * 0.40, y: c.y - h / 2)]
        let p = CGMutablePath()
        p.move(to: CGPoint(x: (tri[0].x + tri[2].x) / 2, y: (tri[0].y + tri[2].y) / 2))
        p.addArc(tangent1End: tri[0], tangent2End: tri[1], radius: corner)
        p.addArc(tangent1End: tri[1], tangent2End: tri[2], radius: corner)
        p.addArc(tangent1End: tri[2], tangent2End: tri[0], radius: corner)
        p.closeSubpath()
        return p
    }

    // Echo behind, offset left: the "stream".
    let echo = playPath(center: CGPoint(x: 395 * u, y: 512 * u), height: 360 * u, corner: 50 * u)
    ctx.addPath(echo)
    ctx.setFillColor(color(0xFFFFFF, 0.42))
    ctx.fillPath()

    // Main mark with a soft drop shadow and a faint vertical tint.
    let mark = playPath(center: CGPoint(x: 590 * u, y: 512 * u), height: 360 * u, corner: 50 * u)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * u), blur: 36 * u, color: color(0x6A0F3A, 0.45))
    ctx.addPath(mark)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(mark)
    ctx.clip()
    let tint = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF), color(0xFFE6DA)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(tint, start: CGPoint(x: 0, y: 712 * u), end: CGPoint(x: 0, y: 312 * u), options: [])
    ctx.restoreGState()

    // Hairline highlight on the tile edge.
    ctx.addPath(tilePath)
    ctx.setStrokeColor(color(0xFFFFFF, 0.18))
    ctx.setLineWidth(3 * u)
    ctx.strokePath()
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (base, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let px = base * scale
        let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        drawIcon(size: CGFloat(px), in: ctx)
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
    }
}
print("Wrote \(out)")
