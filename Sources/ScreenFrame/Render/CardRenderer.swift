import AVFoundation
import CoreImage

/// Renders a brand intro/outro card (gradient, title, logo, a slow push-in) to a short MP4 that is
/// added as a normal clip.
enum CardRenderer {
    static func render(text: String, kit: BrandKit, size: CGSize, duration: Double = 2.5, to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let base = card(text: text, kit: kit, size: size)
        let context = CIContext()
        let fps = 30, frames = Int(duration * Double(fps))
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { break }
            let p = Double(i) / Double(frames)
            let zoom = 1 + 0.04 * p
            let alpha = min(1, min(p / 0.15, (1 - p) / 0.15))
            let frame = base
                .transformed(by: CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2))
                .transformed(by: CGAffineTransform(scaleX: zoom, y: zoom))
                .transformed(by: CGAffineTransform(translationX: size.width / 2, y: size.height / 2))
                .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)])
                .composited(over: CIImage(color: .black))
                .cropped(to: CGRect(origin: .zero, size: size))
            context.render(frame, to: buffer)
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    private static func card(text: String, kit: BrandKit, size: CGSize) -> CIImage {
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: Backdrop.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let gradient = CGGradient(colorsSpace: Backdrop.colorSpace, colors: kit.gradient.map { CGColor.hex($0) } as CFArray, locations: nil)!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
        var image = CIImage(cgImage: ctx.makeImage()!)
        let title = TextOverlay(text: text, start: 0, end: 1, x: 0.5, y: 0.5, size: 0.085, color: kit.textColor, style: .plain,
                                fontName: kit.fontPostScriptName)
        image = TextRenderer(texts: [title], canvas: size).render(over: image, at: 0.5)
        if let path = kit.logoPath,
           let logo = Composer.makeWatermark(Watermark(path: path, corner: .bottomRight, size: 0.07, opacity: 1), canvas: size) {
            // Logo centred under the title.
            let shifted = logo.transformed(by: CGAffineTransform(translationX: size.width / 2 - logo.extent.midX,
                                                                 y: size.height * 0.28 - logo.extent.midY))
            image = shifted.composited(over: image)
        }
        return image
    }
}
