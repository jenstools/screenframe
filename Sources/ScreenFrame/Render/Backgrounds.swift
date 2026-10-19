import AppKit
import CoreImage

struct BackgroundPreset: Identifiable {
    enum Kind { case gradient([UInt32]), solid(UInt32), wallpaper }

    let id: String
    let name: String
    let kind: Kind

    static let all: [BackgroundPreset] = [
        .init(id: "aurora", name: "Aurora", kind: .gradient([0x7F5AF0, 0x2CB1BC])),
        .init(id: "sunset", name: "Sunset", kind: .gradient([0xFF6A88, 0xFF99AC, 0xFCC59B])),
        .init(id: "ocean", name: "Ocean", kind: .gradient([0x1E3C72, 0x2A5298, 0x6DD5FA])),
        .init(id: "candy", name: "Candy", kind: .gradient([0xFC5C7D, 0x6A82FB])),
        .init(id: "forest", name: "Forest", kind: .gradient([0x134E5E, 0x71B280])),
        .init(id: "peach", name: "Peach", kind: .gradient([0xFFDDE1, 0xEE9CA7])),
        .init(id: "lime", name: "Lime", kind: .gradient([0xD4FC79, 0x96E6A1])),
        .init(id: "midnight", name: "Midnight", kind: .gradient([0x0F2027, 0x203A43, 0x2C5364])),
        .init(id: "graphite", name: "Graphite", kind: .solid(0x1C1C1E)),
        .init(id: "paper", name: "Paper", kind: .solid(0xF2F2F5)),
        .init(id: "wallpaper", name: "Wallpaper", kind: .wallpaper),
    ]

    static func named(_ id: String) -> BackgroundPreset {
        all.first { $0.id == id } ?? all[0]
    }
}

extension CGColor {
    static func hex(_ value: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }
}

/// Draws the static part of every frame once per settings change: background, the drop shadow
/// under the screen, and the rounded-corner mask. Only the video and cursor change per frame.
enum Backdrop {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let ciContext = CIContext(options: [.workingColorSpace: colorSpace])

    static func make(canvas: CGSize, videoRect: CGRect, radius: CGFloat, unit: CGFloat,
                     settings: EditSettings) -> (backdrop: CIImage, mask: CIImage) {
        let width = Int(canvas.width), height = Int(canvas.height)
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let bounds = CGRect(origin: .zero, size: canvas)

        let kind: BackgroundPreset.Kind = settings.background == "custom" && (settings.customGradient?.count ?? 0) >= 2
            ? .gradient(settings.customGradient!) : BackgroundPreset.named(settings.background).kind
        switch kind {
        case .gradient(let colors):
            let gradient = CGGradient(colorsSpace: colorSpace, colors: colors.map { CGColor.hex($0) } as CFArray, locations: nil)!
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: canvas.height), end: CGPoint(x: canvas.width, y: 0), options: [])
        case .solid(let color):
            ctx.setFillColor(CGColor.hex(color))
            ctx.fill(bounds)
        case .wallpaper:
            if let image = wallpaper(blur: settings.backgroundBlur * unit) {
                let scale = max(canvas.width / CGFloat(image.width), canvas.height / CGFloat(image.height))
                let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
                                           width: size.width, height: size.height))
            } else {
                ctx.setFillColor(CGColor.hex(0x1C1C1E))
                ctx.fill(bounds)
            }
        }

        let path = CGPath(roundedRect: videoRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if settings.shadow > 0 {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -16 * unit), blur: 48 * unit,
                          color: CGColor(gray: 0, alpha: min(1, settings.shadow * 0.75)))
            ctx.addPath(path)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fillPath()
            ctx.restoreGState()
        }

        let maskCtx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        maskCtx.setFillColor(gray: 0, alpha: 1)
        maskCtx.fill(bounds)
        maskCtx.addPath(path)
        maskCtx.setFillColor(gray: 1, alpha: 1)
        maskCtx.fillPath()

        return (CIImage(cgImage: ctx.makeImage()!), CIImage(cgImage: maskCtx.makeImage()!))
    }

    private static var wallpaperCache: (blur: Double, image: CGImage)?
    private static let lock = NSLock()

    /// The current desktop picture of the main screen, optionally blurred.
    static func wallpaper(blur: Double) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = wallpaperCache, abs(cached.blur - blur) < 0.5 { return cached.image }
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              var image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        if blur > 0.5 {
            let ci = CIImage(cgImage: image)
            let blurred = ci.clampedToExtent().applyingGaussianBlur(sigma: blur).cropped(to: ci.extent)
            if let rendered = ciContext.createCGImage(blurred, from: ci.extent) { image = rendered }
        }
        wallpaperCache = (blur, image)
        return image
    }
}
