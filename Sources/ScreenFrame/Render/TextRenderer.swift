import AppKit
import CoreImage
import CoreText

/// Draws the text elements on top of the finished frame, in output space (they don't zoom with
/// the camera). Each element fades and rises in over 0.25 s. Rendered sprites are cached.
final class TextRenderer: @unchecked Sendable {
    private let texts: [TextOverlay]
    private let canvas: CGSize
    private var sprites: [String: CIImage] = [:]
    private let lock = NSLock()

    init(texts: [TextOverlay], canvas: CGSize) {
        self.texts = texts.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        self.canvas = canvas
    }

    var isEmpty: Bool { texts.isEmpty }

    func render(over image: CIImage, at t: Double) -> CIImage {
        var result = image
        for text in texts where t >= text.start && t < text.end {
            guard let sprite = sprite(for: text) else { continue }
            let fade = 0.25
            let alpha = max(0, min(1, (t - text.start) / fade, (text.end - t) / fade))
            let rise = (1 - (1 - pow(1 - alpha, 3))) * canvas.height * 0.012
            // Keep the whole element inside the frame (long wrapped titles near an edge).
            let margin = min(canvas.width, canvas.height) * 0.025
            let halfW = sprite.extent.width / 2, halfH = sprite.extent.height / 2
            let center = CGPoint(x: min(max(text.x * canvas.width, halfW + margin), canvas.width - halfW - margin),
                                 y: min(max((1 - text.y) * canvas.height, halfH + margin), canvas.height - halfH - margin) - rise)
            var placed = sprite.transformed(by: CGAffineTransform(translationX: center.x - sprite.extent.width / 2,
                                                                  y: center.y - sprite.extent.height / 2))
            if alpha < 1 {
                placed = placed.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)])
            }
            result = placed.composited(over: result)
        }
        return result
    }

    private func sprite(for text: TextOverlay) -> CIImage? {
        let key = "\(text.text)|\(text.size)|\(text.color)|\(text.style.rawValue)|\(text.fontName ?? "")|\(text.pillColor ?? 0)|\(text.wrapWidth ?? 0)|\(text.uppercase ?? false)"
        lock.lock()
        defer { lock.unlock() }
        if let cached = sprites[key] { return cached }
        guard let image = Self.draw(text, canvas: canvas) else { return nil }
        let sprite = CIImage(cgImage: image)
        sprites[key] = sprite
        return sprite
    }

    /// Size of the drawn text element in output pixels (used for hit-testing on the preview).
    static func measure(_ text: TextOverlay, canvas: CGSize) -> CGSize {
        layout(text, canvas: canvas).size
    }

    private struct Layout {
        let lines: [CTLine]
        let widths: [CGFloat]
        let ascent: CGFloat
        let lineHeight: CGFloat
        let padding: CGSize
        let size: CGSize
    }

    /// Lines wrap at word boundaries to fit 88% of the frame width (matters most in 9:16).
    private static func layout(_ text: TextOverlay, canvas: CGSize) -> Layout {
        let fontSize = max(6, text.size * canvas.height)
        let font = text.fontName.flatMap { NSFont(name: $0, size: fontSize) } ?? NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CGColor.hex(text.color)]
        let inset = text.style == .pill ? fontSize * 0.6 : fontSize * 0.35
        let maxWidth = max(fontSize * 4, canvas.width * (text.wrapWidth ?? 0.88) - 2 * inset)
        func width(_ string: String) -> CGFloat {
            CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes)),
                                               nil, nil, nil))
        }
        var wrapped: [String] = []
        let shown = text.uppercase == true ? text.text.uppercased() : text.text
        for paragraph in shown.components(separatedBy: "\n") {
            var line = ""
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
                let candidate = line.isEmpty ? word : line + " " + word
                if !line.isEmpty, width(candidate) > maxWidth {
                    wrapped.append(line)
                    line = word
                } else {
                    line = candidate
                }
            }
            wrapped.append(line)
        }
        let lines = wrapped.map {
            CTLineCreateWithAttributedString(NSAttributedString(string: $0.isEmpty ? " " : $0, attributes: attributes))
        }
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let widths = lines.map { CGFloat(CTLineGetTypographicBounds($0, &ascent, &descent, &leading)) }
        let lineHeight = ascent + descent + max(leading, fontSize * 0.12)
        let padding = text.style == .pill ? CGSize(width: fontSize * 0.6, height: fontSize * 0.32)
                                          : CGSize(width: fontSize * 0.35, height: fontSize * 0.35)
        let size = CGSize(width: ceil((widths.max() ?? 0) + 2 * padding.width),
                          height: ceil(lineHeight * CGFloat(lines.count) - max(leading, fontSize * 0.12) + 2 * padding.height))
        return Layout(lines: lines, widths: widths, ascent: ascent, lineHeight: lineHeight, padding: padding, size: size)
    }

    private static func draw(_ text: TextOverlay, canvas: CGSize) -> CGImage? {
        let layout = layout(text, canvas: canvas)
        let fontSize = max(6, text.size * canvas.height)
        guard layout.size.width > 0, layout.size.height > 0,
              let ctx = CGContext(data: nil, width: Int(layout.size.width), height: Int(layout.size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: Backdrop.colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        switch text.style {
        case .pill:
            // Dark pill behind light text, light pill behind dark text.
            let r = Double((text.color >> 16) & 0xFF), g = Double((text.color >> 8) & 0xFF), b = Double(text.color & 0xFF)
            let light = (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.5
            let rect = CGRect(origin: .zero, size: layout.size)
            let radius = min(rect.height / 2, fontSize * 0.55)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.setFillColor(text.pillColor.map { CGColor.hex($0, alpha: 0.92) }
                             ?? (light ? CGColor(gray: 0, alpha: 0.62) : CGColor(gray: 1, alpha: 0.88)))
            ctx.fillPath()
        case .shadow:
            ctx.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.04), blur: fontSize * 0.22, color: CGColor(gray: 0, alpha: 0.7))
        case .outline:
            // Stroke pass first (round joins), then the fill on top.
            ctx.setLineJoin(.round)
            ctx.setLineWidth(fontSize * 0.16)
            ctx.setStrokeColor(text.pillColor.map { CGColor.hex($0) } ?? CGColor(gray: 0, alpha: 1))
            ctx.setTextDrawingMode(.stroke)
            for (i, line) in layout.lines.enumerated() {
                ctx.textPosition = position(i)
                CTLineDraw(line, ctx)
            }
            ctx.setTextDrawingMode(.fill)
        case .plain:
            break
        }

        func position(_ i: Int) -> CGPoint {
            CGPoint(x: (layout.size.width - layout.widths[i]) / 2,
                    y: layout.size.height - layout.padding.height - layout.ascent - CGFloat(i) * layout.lineHeight)
        }
        for (i, line) in layout.lines.enumerated() {
            ctx.textPosition = position(i)
            CTLineDraw(line, ctx)
        }
        return ctx.makeImage()
    }
}
