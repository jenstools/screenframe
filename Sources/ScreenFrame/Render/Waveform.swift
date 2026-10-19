import AVFoundation

/// Peak levels (0…1) of an audio file, `perSecond` values per second, for the timeline lanes.
enum Waveform {
    static let perSecond = 50

    static func peaks(of url: URL) async -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return [] }
        let sampleRate = 8_000
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: sampleRate,
        ])
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }

        let window = sampleRate / perSecond
        var peaks: [Float] = []
        var current: Int16 = 0
        var count = 0
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                              dataPointerOut: &pointer) == kCMBlockBufferNoErr, let pointer else { continue }
            pointer.withMemoryRebound(to: Int16.self, capacity: length / 2) { samples in
                for i in 0..<(length / 2) {
                    let value = samples[i] == Int16.min ? Int16.max : abs(samples[i])
                    if value > current { current = value }
                    count += 1
                    if count == window {
                        peaks.append(Float(current) / Float(Int16.max))
                        current = 0
                        count = 0
                    }
                }
            }
        }
        // Scale so normal speech fills the lane; quiet tracks stay visibly quiet.
        let loudest = peaks.max() ?? 0
        guard loudest > 0 else { return peaks }
        let gain = min(4, 0.9 / loudest)
        return peaks.map { min(1, $0 * gain) }
    }
}
