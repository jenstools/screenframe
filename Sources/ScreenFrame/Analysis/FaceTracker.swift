import AVFoundation
import Vision

/// Where the face is in the camera video over time (Vision, on-device), so the bubble can keep it
/// centred. Results are cached next to the video as `<file>.faces.json`.
enum FaceTracker {
    struct Point: Codable {
        var t: Double
        /// Face centre, normalized, top-left origin.
        var x: Double
        var y: Double
        /// Face height as a share of the picture.
        var size: Double
    }

    static func cacheURL(for video: URL) -> URL { video.appendingPathExtension("faces.json") }

    static func cached(for video: URL) -> [Point]? {
        guard let data = try? Data(contentsOf: cacheURL(for: video)) else { return nil }
        return try? JSONDecoder().decode([Point].self, from: data)
    }

    /// Samples 4 frames a second. Frames without a face are skipped; the renderer holds the last one.
    static func track(_ video: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [Point] {
        if let cached = cached(for: video) { return cached }
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 20)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 20)

        var points: [Point] = []
        var t = 0.0
        while t < duration {
            try Task.checkCancellation()
            if let frame = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
                let request = VNDetectFaceRectanglesRequest()
                try? VNImageRequestHandler(cgImage: frame).perform([request])
                // The largest face is the speaker.
                if let face = request.results?.max(by: { $0.boundingBox.height < $1.boundingBox.height }) {
                    let box = face.boundingBox
                    points.append(Point(t: t, x: box.midX, y: 1 - box.midY, size: box.height))
                }
            }
            t += 0.25
            progress(min(1, t / duration))
        }
        try? JSONEncoder().encode(points).write(to: cacheURL(for: video))
        return points
    }
}
