// Draws Resources/AppIcon.icns: aurora gradient squircle, a framed "screen" and a cursor.
import AppKit

func draw(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    let inset = s * 0.09
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let squircle = CGPath(roundedRect: body, cornerWidth: s * 0.2, cornerHeight: s * 0.2, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.015), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(squircle); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    let colors = [CGColor(srgbRed: 0.50, green: 0.35, blue: 0.94, alpha: 1), CGColor(srgbRed: 0.17, green: 0.69, blue: 0.74, alpha: 1)]
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
    ctx.restoreGState()

    // The "screen": a white rounded window with a shadow, like a framed recording.
    let screen = body.insetBy(dx: s * 0.13, dy: s * 0.2).offsetBy(dx: 0, dy: s * 0.02)
    let screenPath = CGPath(roundedRect: screen, cornerWidth: s * 0.05, cornerHeight: s * 0.05, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.02), blur: s * 0.05, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(screenPath); ctx.setFillColor(CGColor(gray: 1, alpha: 0.96)); ctx.fillPath()
    ctx.restoreGState()
    // Title bar dots.
    for (i, c) in [(1.0, 0.37, 0.34), (1.0, 0.74, 0.18), (0.16, 0.79, 0.25)].enumerated() {
        ctx.setFillColor(CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1))
        let r = s * 0.022
        ctx.fillEllipse(in: CGRect(x: screen.minX + s * 0.045 + CGFloat(i) * r * 2.8, y: screen.maxY - s * 0.06, width: r * 2, height: r * 2))
    }

    // Cursor arrow (classic shape), bottom-right, overlapping the screen.
    let unit = s * 0.0105
    let tip = CGPoint(x: screen.midX + s * 0.06, y: screen.midY + s * 0.02)
    let pts: [(CGFloat, CGFloat)] = [(0, 0), (0, -23), (5.5, -17.5), (9.5, -26), (13.5, -24.2), (9.6, -16), (17, -16)]
    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: tip.x + pts[0].0 * unit, y: tip.y + pts[0].1 * unit))
    for p in pts.dropFirst() { arrow.addLine(to: CGPoint(x: tip.x + p.0 * unit, y: tip.y + p.1 * unit)) }
    arrow.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.02, color: CGColor(gray: 0, alpha: 0.4))
    ctx.addPath(arrow); ctx.setFillColor(CGColor(gray: 0.08, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(arrow); ctx.setStrokeColor(CGColor(gray: 1, alpha: 1)); ctx.setLineWidth(unit * 1.6); ctx.setLineJoin(.round); ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! draw(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! draw(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! p.run(); p.waitUntilExit()
try! draw(1024).write(to: out.deletingPathExtension().appendingPathExtension("png"))
print("wrote \(out.path)")
