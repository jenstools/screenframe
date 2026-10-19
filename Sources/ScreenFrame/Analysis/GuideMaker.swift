import AVFoundation
import AppKit
import CoreText
import Vision

/// Recording → illustrated step-by-step guide. One step per click: a screenshot with the click
/// marked, the clicked label read off the screen (on-device), and step text written by Claude
/// from that label plus what was said. Exported as HTML, Markdown and PDF.
enum GuideMaker {
    struct Step {
        var number: Int
        var time: Double
        var label: String
        var said: String
        var image: CGImage
        var title = ""
        var text = ""
    }

    static func build(placements: [ClipPlacement], lines: [Captioner.Word], name: String, language: String,
                      kit: BrandKit?, into project: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let german = language.hasPrefix("de")
        // Clicks close together (double clicks, quick fixes) are one step.
        var clicks: [(p: ClipPlacement, click: ClickEvent)] = []
        for p in placements {
            for click in p.media.info.clicks where click.down && click.t >= p.clip.start && click.t < p.clip.end {
                if let last = clicks.last, last.p.clip.id == p.clip.id, click.t - last.click.t < 1.2,
                   hypot(click.x - last.click.x, click.y - last.click.y) < 0.05 * hypot(p.media.info.sourceWidth, p.media.info.sourceHeight) {
                    continue
                }
                clicks.append((p, click))
            }
        }
        clicks = Array(clicks.prefix(40))
        guard !clicks.isEmpty else {
            throw NSError(domain: "ScreenFrame", code: 4, userInfo: [NSLocalizedDescriptionKey: german
                ? "Keine Klicks in der Aufnahme, daraus lässt sich keine Anleitung bauen."
                : "This recording has no clicks to build steps from."])
        }

        var steps: [Step] = []
        for (i, item) in clicks.enumerated() {
            let t = item.p.timelineTime(item.click.t)
            let frame = try await screenshot(item.p.media, at: item.click.t)
            let w = Double(frame.width), h = Double(frame.height)
            let point = CGPoint(x: item.click.x / item.p.media.info.sourceWidth * w, y: item.click.y / item.p.media.info.sourceHeight * h)
            let label = readLabel(frame, near: point)
            let said = lines.filter { $0.end > t - 5 && $0.start < t + 2 }.map(\.text).joined(separator: " ")
            steps.append(Step(number: i + 1, time: t, label: label, said: said, image: marked(frame, at: point, number: i + 1)))
            progress(Double(i + 1) / Double(clicks.count) * 0.7)
        }

        var title = name, intro = ""
        if let written = try? await write(steps: steps, name: name, german: german) {
            title = written.title.isEmpty ? name : written.title
            intro = written.intro
            for (i, step) in written.steps.enumerated() where i < steps.count {
                steps[i].title = step.title
                steps[i].text = step.text
            }
        }
        for i in steps.indices where steps[i].title.isEmpty {
            steps[i].title = german ? "Schritt \(steps[i].number)" : "Step \(steps[i].number)"
            steps[i].text = steps[i].label.isEmpty ? "" : (german ? "Klicke auf „\(steps[i].label)“." : "Click “\(steps[i].label)”.")
        }
        progress(0.85)

        let folder = project.appendingPathComponent("guide", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for step in steps { try jpeg(step.image, to: folder.appendingPathComponent(String(format: "step-%02d.jpg", step.number))) }
        try html(title: title, intro: intro, steps: steps, kit: kit).write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try markdown(title: title, intro: intro, steps: steps).write(to: folder.appendingPathComponent("guide.md"), atomically: true, encoding: .utf8)
        try pdf(title: title, intro: intro, steps: steps, kit: kit, to: folder.appendingPathComponent("guide.pdf"))
        progress(1)
        return folder
    }

    // MARK: Capture

    private static func screenshot(_ media: ClipMedia, at s: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: media.videoURL))
        generator.maximumSize = CGSize(width: 1800, height: 1800)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: max(0, s - 0.05), preferredTimescale: 600)).image
    }

    /// The text closest to the click (button or menu label), read with Vision around the click.
    private static func readLabel(_ frame: CGImage, near point: CGPoint) -> String {
        let w = Double(frame.width), h = Double(frame.height)
        let crop = CGRect(x: max(0, point.x - w * 0.15), y: max(0, point.y - h * 0.06), width: w * 0.3, height: h * 0.12)
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard let region = frame.cropping(to: crop) else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["de-DE", "en-US"]
        try? VNImageRequestHandler(cgImage: region).perform([request])
        let local = CGPoint(x: (point.x - crop.minX) / crop.width, y: 1 - (point.y - crop.minY) / crop.height)
        let nearest = (request.results ?? []).min { a, b in
            hypot(a.boundingBox.midX - local.x, a.boundingBox.midY - local.y) < hypot(b.boundingBox.midX - local.x, b.boundingBox.midY - local.y)
        }
        return nearest?.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// Screenshot with a ring and step number at the click.
    private static func marked(_ frame: CGImage, at point: CGPoint, number: Int) -> CGImage {
        let w = frame.width, h = frame.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: Backdrop.colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return frame }
        ctx.draw(frame, in: CGRect(x: 0, y: 0, width: w, height: h))
        let r = Double(w) * 0.022
        let center = CGPoint(x: point.x, y: Double(h) - point.y)
        ctx.setStrokeColor(CGColor.hex(0xFF3B30))
        ctx.setLineWidth(r * 0.22)
        ctx.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        let badge = CGRect(x: center.x + r * 0.6, y: center.y + r * 0.6, width: r * 1.3, height: r * 1.3)
        ctx.setFillColor(CGColor.hex(0xFF3B30))
        ctx.fillEllipse(in: badge)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: r * 0.8, weight: .bold),
                                                         .foregroundColor: CGColor.hex(0xFFFFFF)]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "\(number)", attributes: attributes))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.textPosition = CGPoint(x: badge.midX - width / 2, y: badge.midY - r * 0.28)
        CTLineDraw(line, ctx)
        return ctx.makeImage() ?? frame
    }

    // MARK: Writing

    private struct Written: Decodable {
        struct Item: Decodable { var title: String; var text: String }
        var title: String
        var intro: String
        var steps: [Item]
    }

    private static func write(steps: [Step], name: String, german: Bool) async throws -> Written {
        let system = """
        You write clear step-by-step software guides from a screen recording. Language: \(german ? "German, informal du" : "English"). \
        For every step you get what was clicked (text read from the screen, may be imperfect) and what the presenter said around it. \
        Write a short imperative title (max 8 words) and 1–2 sentences of explanation per step, in the same order and count. \
        Answer with ONLY JSON: {"title": "...", "intro": "one sentence", "steps": [{"title": "...", "text": "..."}]}
        """
        let input = steps.map { ["n": $0.number, "clicked": $0.label, "said": $0.said] as [String: Any] }
        let data = try JSONSerialization.data(withJSONObject: ["video": name, "steps": input], options: .prettyPrinted)
        let answer = try await AIClient.ask(system: system, prompt: String(data: data, encoding: .utf8) ?? "")
        let json = try AIClient.json(in: answer)
        return try JSONDecoder().decode(Written.self, from: JSONSerialization.data(withJSONObject: json))
    }

    // MARK: Output

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func hex(_ value: UInt32) -> String { String(format: "#%06X", value) }

    private static func html(title: String, intro: String, steps: [Step], kit: BrandKit?) -> String {
        let accent = hex(kit?.gradient.first ?? 0x7F5AF0), font = kit?.font ?? "-apple-system"
        let items = steps.map { step in
            """
            <section class="step"><div class="n">\(step.number)</div><div class="body"><h2>\(escape(step.title))</h2>
            <p>\(escape(step.text))</p><img src="\(String(format: "step-%02d.jpg", step.number))" alt="\(escape(step.title))"></div></section>
            """
        }.joined(separator: "\n")
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(escape(title))</title><style>
        body{font-family:'\(font)',-apple-system,sans-serif;max-width:920px;margin:40px auto;padding:0 24px;color:#1d1d1f;line-height:1.5}
        h1{font-size:34px;margin-bottom:6px}.intro{color:#555;font-size:18px;margin-bottom:36px}
        .step{display:flex;gap:18px;margin:0 0 40px}.n{flex:none;width:38px;height:38px;border-radius:50%;background:\(accent);color:#fff;
        font-weight:700;display:flex;align-items:center;justify-content:center;font-size:18px}.body{flex:1}h2{margin:4px 0 6px;font-size:21px}
        img{width:100%;border-radius:10px;box-shadow:0 6px 24px rgba(0,0,0,.15);margin-top:10px}
        </style></head><body><h1>\(escape(title))</h1><p class="intro">\(escape(intro))</p>
        \(items)
        </body></html>
        """
    }

    private static func markdown(title: String, intro: String, steps: [Step]) -> String {
        "# \(title)\n\n\(intro)\n\n" + steps.map {
            "## \($0.number). \($0.title)\n\n\($0.text)\n\n![\($0.title)](\(String(format: "step-%02d.jpg", $0.number)))\n"
        }.joined(separator: "\n")
    }

    /// A4 PDF: title page, then one step per page (title, text, screenshot).
    private static func pdf(title: String, intro: String, steps: [Step], kit: BrandKit?, to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        let margin: CGFloat = 50
        let fontName = kit?.fontPostScriptName
        func font(_ size: CGFloat, bold: Bool) -> NSFont {
            fontName.flatMap { NSFont(name: $0, size: size) } ?? NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        }
        func draw(_ text: String, size: CGFloat, bold: Bool, top: CGFloat, color: UInt32 = 0x1D1D1F) -> CGFloat {
            let attributed = NSAttributedString(string: text, attributes: [.font: font(size, bold: bold), .foregroundColor: CGColor.hex(color)])
            let setter = CTFramesetterCreateWithAttributedString(attributed)
            let width = box.width - 2 * margin
            let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil)
            let rect = CGRect(x: margin, y: box.height - top - fit.height, width: width, height: fit.height)
            CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: rect, transform: nil), nil), ctx)
            return top + fit.height
        }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor.hex(kit?.gradient.first ?? 0x7F5AF0))
        ctx.fill(CGRect(x: 0, y: box.height - 14, width: box.width, height: 14))
        var y = draw(title, size: 30, bold: true, top: 120)
        y = draw(intro, size: 14, bold: false, top: y + 16, color: 0x555555)
        _ = draw(steps.map { "\($0.number). \($0.title)" }.joined(separator: "\n"), size: 12, bold: false, top: y + 30)
        ctx.endPDFPage()
        for step in steps {
            ctx.beginPDFPage(nil)
            var top = draw("\(step.number). \(step.title)", size: 20, bold: true, top: margin)
            if !step.text.isEmpty { top = draw(step.text, size: 12, bold: false, top: top + 10, color: 0x333333) }
            let width = box.width - 2 * margin
            let height = width * CGFloat(step.image.height) / CGFloat(step.image.width)
            ctx.draw(step.image, in: CGRect(x: margin, y: box.height - top - 20 - height, width: width, height: height))
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    private static func jpeg(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
