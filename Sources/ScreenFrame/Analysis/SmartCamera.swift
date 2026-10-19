import Foundation

/// "Auto layout": the camera goes full screen while you talk and nothing happens on screen for a
/// few seconds, and back to the bubble when you click, type or move the mouse again.
enum SmartCamera {
    static func autoLayout(placements: [ClipPlacement], waveforms: [String: [Float]], position: CGPoint,
                           minimum: Double = 3) -> [CameraKey] {
        var keys: [CameraKey] = []
        for p in placements where p.media.info.webcam != nil {
            guard let track = Cleanup.voiceTrack(of: p),
                  let peaks = waveforms[p.media.folder.appendingPathComponent(track.file).path], peaks.count > 10 else { continue }
            let sorted = peaks.sorted()
            let floor = Double(sorted[sorted.count / 5]), loud = Double(sorted[sorted.count * 9 / 10])
            let threshold = max(0.03, floor + 0.25 * (loud - floor))
            let perSecond = Double(Waveform.perSecond)
            let info = p.media.info
            let diagonal = hypot(info.sourceWidth, info.sourceHeight)

            func talking(_ t: Double) -> Bool {
                // Any speech within ±0.6 s counts, so short breaths don't flip the layout.
                let s = p.sourceTime(t) - track.offset
                let i0 = max(0, Int((s - 0.6) * perSecond)), i1 = min(peaks.count, Int((s + 0.6) * perSecond))
                return i0 < i1 && Double(peaks[i0..<i1].max() ?? 0) > threshold
            }
            func idle(_ t: Double) -> Bool {
                let s0 = p.sourceTime(t) - 1, s1 = p.sourceTime(t) + 1
                if info.clicks.contains(where: { $0.t >= s0 && $0.t <= s1 }) { return false }
                if (info.keystrokes ?? []).contains(where: { $0 >= s0 && $0 <= s1 }) { return false }
                let moves = info.mouse.filter { $0.t >= s0 && $0.t <= s1 }
                var distance = 0.0
                for (a, b) in zip(moves, moves.dropFirst()) { distance += hypot(b.x - a.x, b.y - a.y) }
                return distance < 0.01 * diagonal
            }

            var runStart: Double?
            var t = p.offset + p.overlapIn
            let end = p.end - p.overlapOut
            func close(at stop: Double) {
                guard let start = runStart else { return }
                runStart = nil
                guard stop - start >= minimum else { return }
                keys.append(CameraKey(t: start, x: position.x, y: position.y, layout: .fullscreen, auto: true))
                keys.append(CameraKey(t: stop, x: position.x, y: position.y, layout: .overlay, auto: true))
            }
            while t < end {
                if talking(t) && idle(t) { if runStart == nil { runStart = t } } else { close(at: t) }
                t += 0.25
            }
            close(at: end)
        }
        return keys
    }
}
