import Foundation

/// Turns clicks into zoom segments: clicks close in time and space form one group, the zoom starts
/// shortly before the first click (so the camera has arrived when it happens) and holds a little
/// after the last one.
enum AutoZoom {
    static let maxGap = 3.0            // seconds between clicks in one group
    static let maxDistance = 0.35      // fraction of the source diagonal
    static let leadIn = 0.9
    static let holdOut = 1.8
    static let minLength = 1.6
    static let mergeGap = 0.7

    static func generate(info: RecordingInfo, zoom: Double) -> [ZoomSegment] {
        let downs = info.clicks.filter { $0.down && $0.button == 0 }.sorted { $0.t < $1.t }
        guard !downs.isEmpty else { return [] }
        let diagonal = hypot(info.sourceWidth, info.sourceHeight)

        var groups: [[ClickEvent]] = []
        for click in downs {
            if let first = groups.last?.first, let last = groups.last?.last,
               click.t - last.t <= maxGap,
               hypot(click.x - first.x, click.y - first.y) <= maxDistance * diagonal {
                groups[groups.count - 1].append(click)
            } else {
                groups.append([click])
            }
        }

        var segments: [ZoomSegment] = []
        for group in groups {
            var start = max(0, group[0].t - leadIn)
            var end = min(info.duration, group[group.count - 1].t + holdOut)
            if end - start < minLength {
                end = min(info.duration, start + minLength)
                start = max(0, end - minLength)
            }
            if let previous = segments.last, start - previous.end < mergeGap {
                segments[segments.count - 1].end = max(previous.end, end)
            } else {
                segments.append(ZoomSegment(start: start, end: end, zoom: zoom))
            }
        }
        return segments
    }
}
