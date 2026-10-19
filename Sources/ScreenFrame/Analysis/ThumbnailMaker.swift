import AVFoundation
import CoreImage
import Vision

/// Thumbnails: picks strong frames (a visible face, a detailed screen), then composes a cover
/// with a big headline, an optional cut-out of you from the camera and the brand logo.
enum ThumbnailMaker {
    struct Candidate: Identifiable {
        let id = UUID()
        let time: Double
        let image: CGImage
        let score: Double
    }

    enum Format: String, CaseIterable, Identifiable {
        case youtube, linkedin, square
        var id: String { rawValue }
        var label: String {
            switch self {
            case .youtube: return "YouTube 16:9"
            case .linkedin: return "LinkedIn 1.91:1"
            case .square: return "Square 1:1"
            }
        }
        var size: CGSize {
            switch self {
            case .youtube: return CGSize(width: 1280, height: 720)
            case .linkedin: return CGSize(width: 1200, height: 627)
            case .square: return CGSize(width: 1080, height: 1080)
            }
        }
    }

    private static let context = CIContext()

    /// The project without titles, captions and logo (they don't belong in a thumbnail frame).
    private static func clean(_ project: Project, hideCamera: Bool) -> Project {
        var p = project
        p.doc.texts = []
        p.doc.settings.watermark = nil
        if hideCamera { p.doc.settings.showCamera = false }
        return p
    }

    static func candidates(project: Project, count: Int = 3) async throws -> [Candidate] {
        let built = try await Composer.build(project: clean(project, hideCamera: false), maxLongSide: 640, resolution: nil)
        let duration = try await built.asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: built.asset)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)

        let samples = min(28, max(6, Int(duration / 1.2)))
        var scored: [Candidate] = []
        for i in 0..<samples {
            let t = duration * (Double(i) + 0.5) / Double(samples)
            guard let image = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image else { continue }
            scored.append(Candidate(time: t, image: image, score: score(image)))
        }
        // Best first, at least a sixth of the video apart so the picks differ.
        var picks: [Candidate] = []
        for candidate in scored.sorted(by: { $0.score > $1.score }) where picks.count < count {
            if picks.allSatisfy({ abs($0.time - candidate.time) > duration / 6 }) { picks.append(candidate) }
        }
        return picks
    }

    /// Face (size, centred) plus detail (gradient energy of a small grayscale copy).
    private static func score(_ image: CGImage) -> Double {
        let faces = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image).perform([faces])
        let face = faces.results?.map { Double($0.boundingBox.height) }.max() ?? 0
        let w = 64, h = 36
        var pixels = [UInt8](repeating: 0, count: w * h)
        if let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                               space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) {
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var energy = 0.0
        for y in 0..<h { for x in 1..<w { energy += abs(Double(pixels[y * w + x]) - Double(pixels[y * w + x - 1])) } }
        let mean = Double(pixels.reduce(0) { $0 + Int($1) }) / Double(pixels.count)
        let exposure = 1 - abs(mean - 120) / 120
        return min(1, face * 3) * 2 + min(1, energy / Double(w * h) / 25) + exposure * 0.5
    }

    /// The finished thumbnail at timeline time `t`.
    static func compose(project: Project, at t: Double, headline: String, kit: BrandKit?, faceCutout: Bool,
                        format: Format) async throws -> CGImage {
        let size = format.size
        let bounds = CGRect(origin: .zero, size: size)
        let placement = TimelineLayout.place(project.doc.clips, in: project).first { t < $0.end }
        let hasCamera = placement?.media.info.webcam != nil
        let cutout = faceCutout && hasCamera
        let screen = try await Exporter.still(project: clean(project, hideCamera: cutout), at: t, maxLongSide: 1920)

        // Softened and darkened towards the headline side, so the text reads on any screen.
        var image = fill(CIImage(cgImage: screen), into: bounds).clampedToExtent().applyingGaussianBlur(sigma: 3.5).cropped(to: bounds)
        let shade = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: size.width * 0.8, y: 0),
            "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 0.85), "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0.25),
        ])!.outputImage!.cropped(to: bounds)
        image = shade.composited(over: image)

        if cutout, let placement, let person = try? await cutoutPerson(placement, at: placement.sourceTime(t)) {
            let square = format == .square
            let scale = square ? min(size.height * 0.62 / person.extent.height, size.width * 0.75 / person.extent.width)
                               : min(size.height * 0.92 / person.extent.height, size.width * 0.45 / person.extent.width)
            let placed = person
                .transformed(by: CGAffineTransform(translationX: -person.extent.minX, y: -person.extent.minY))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let x = square ? (size.width - placed.extent.width) / 2 : size.width - placed.extent.width - size.width * 0.02
            let moved = placed.transformed(by: CGAffineTransform(translationX: x, y: 0))
            // A soft glow makes the cut-out pop off the background.
            let glow = moved.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0),
            ]).applyingGaussianBlur(sigma: 10).cropped(to: bounds)
            image = moved.composited(over: glow.composited(over: image))
        }

        let square = format == .square
        let text = TextOverlay(text: headline, start: 0, end: 1, x: square ? 0.5 : (cutout ? 0.33 : 0.42), y: square && cutout ? 0.29 : 0.5,
                               size: square ? 0.085 : 0.11, color: kit?.textColor ?? 0xFFFFFF, style: .shadow,
                               fontName: kit?.fontPostScriptName, wrapWidth: square ? 0.88 : (cutout ? 0.6 : 0.78))
        image = TextRenderer(texts: [text], canvas: size).render(over: image, at: 0.5)
        if let path = kit?.logoPath,
           let logo = Composer.makeWatermark(Watermark(path: path, corner: .topLeft, size: 0.075, opacity: 1), canvas: size) {
            image = logo.composited(over: image)
        }
        guard let cg = context.createCGImage(image.cropped(to: bounds), from: bounds) else { throw CocoaError(.fileWriteUnknown) }
        return cg
    }

    /// You, without background, from the camera video at a source time.
    private static func cutoutPerson(_ p: ClipPlacement, at s: Double) async throws -> CIImage? {
        guard let webcam = p.media.info.webcam else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: p.media.folder.appendingPathComponent(webcam.file)))
        generator.appliesPreferredTrackTransform = true
        let frame = try await generator.image(at: CMTime(seconds: max(0, s - webcam.offset), preferredTimescale: 600)).image
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        try VNImageRequestHandler(cgImage: frame).perform([request])
        guard let buffer = request.results?.first?.pixelBuffer else { return nil }
        let image = CIImage(cgImage: frame)
        let raw = CIImage(cvPixelBuffer: buffer)
        let mask = raw.transformed(by: CGAffineTransform(scaleX: image.extent.width / raw.extent.width,
                                                         y: image.extent.height / raw.extent.height))
        let person = image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: image.extent), kCIInputMaskImageKey: mask,
        ])
        // Head and shoulders around the largest face, so people in the background stay out.
        let faces = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: frame).perform([faces])
        let w = image.extent.width, h = image.extent.height
        var crop = image.extent
        if let face = faces.results?.max(by: { $0.boundingBox.height < $1.boundingBox.height })?.boundingBox {
            let width = min(w, face.width * w * 3.2)
            let top = min(h, (face.maxY + face.height * 0.6) * h)
            crop = CGRect(x: min(max(0, face.midX * w - width / 2), w - width), y: 0, width: width, height: top)
        } else if let bounds = personBounds(mask, extent: image.extent) {
            crop = bounds
        }
        // Crop, then mirror like the bubble, with the origin at zero.
        return person.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: crop.width, ty: 0))
    }

    private static func personBounds(_ mask: CIImage, extent: CGRect) -> CGRect? {
        let w = 96, h = Int(96 * extent.height / extent.width)
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let cg = context.createCGImage(mask, from: extent),
              let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var minX = w, maxX = 0, maxY = 0
        for y in 0..<h { for x in 0..<w where pixels[y * w + x] > 128 { minX = min(minX, x); maxX = max(maxX, x); maxY = max(maxY, h - 1 - y) } }
        guard maxX > minX else { return nil }
        // Keep the full height down to the frame's bottom.
        let sx = extent.width / Double(w), sy = extent.height / Double(h)
        return CGRect(x: Double(minX) * sx, y: 0, width: Double(maxX - minX + 1) * sx, height: Double(maxY + 1) * sy)
    }

    private static func fill(_ image: CIImage, into rect: CGRect) -> CIImage {
        let e = image.extent
        let scale = max(rect.width / e.width, rect.height / e.height)
        return image
            .transformed(by: CGAffineTransform(translationX: -e.midX, y: -e.midY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: rect.midX, y: rect.midY))
            .cropped(to: rect)
    }

    static func savePNG(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
