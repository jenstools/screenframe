import Foundation

/// The parts of an edit that structural changes rewrite together.
struct EditContent: Equatable {
    var clips: [Clip]
    var texts: [TextOverlay]
    var cameraKeys: [CameraKey]
}

/// Structural edits on timeline time: split, cut, speed. Everything that lives in timeline time
/// (titles, captions, camera keyframes) is moved along with the content it sat on.
enum EditOps {
    /// Splits clips at timeline times.
    static func split(_ content: EditContent, at times: [Double], project: Project) -> EditContent {
        var result = content
        for time in times.sorted(by: >) {
            guard let p = place(result, project).first(where: { time > $0.offset + 0.05 && time < $0.end - 0.05 }) else { continue }
            let s = p.sourceTime(time)
            guard s - p.clip.start > 0.05, p.clip.end - s > 0.05 else { continue }
            var first = p.clip
            first.end = s
            first.transition = nil
            var second = p.clip
            second.id = UUID()
            second.start = s
            second.zooms = p.clip.zooms.map { var z = $0; z.id = UUID(); return z }
            result.clips[p.index] = first
            result.clips.insert(second, at: p.index + 1)
        }
        return result
    }

    /// Removes timeline ranges (transition overlaps are left alone).
    static func remove(_ ranges: [ClosedRange<Double>], from content: EditContent, project: Project) -> EditContent {
        let merged = merge(ranges)
        guard !merged.isEmpty else { return content }
        let before = place(content, project)
        var cuts: [UUID: [ClosedRange<Double>]] = [:]
        for p in before {
            let lo = p.offset + p.overlapIn, hi = p.end - p.overlapOut
            for r in merged {
                let a = max(r.lowerBound, lo), b = min(r.upperBound, hi)
                if b - a > 0.04 { cuts[p.clip.id, default: []].append(p.sourceTime(a)...p.sourceTime(b)) }
            }
        }
        var lineage: [UUID: UUID] = [:]
        var clips: [Clip] = []
        for clip in content.clips {
            guard let ranges = cuts[clip.id] else {
                clips.append(clip)
                lineage[clip.id] = clip.id
                continue
            }
            var pieces: [ClosedRange<Double>] = []
            var cursor = clip.start
            for cut in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                if cut.lowerBound - cursor > 0.05 { pieces.append(cursor...cut.lowerBound) }
                cursor = max(cursor, cut.upperBound)
            }
            if clip.end - cursor > 0.05 { pieces.append(cursor...clip.end) }
            for (i, piece) in pieces.enumerated() {
                var copy = clip
                if i > 0 {
                    copy.id = UUID()
                    copy.zooms = clip.zooms.map { var z = $0; z.id = UUID(); return z }
                }
                copy.start = piece.lowerBound
                copy.end = piece.upperBound
                copy.transition = i == pieces.count - 1 ? clip.transition : nil
                clips.append(copy)
                lineage[copy.id] = clip.id
            }
        }
        var result = content
        result.clips = clips.isEmpty ? content.clips : clips
        return remap(result, from: before, lineage: lineage, project: project)
    }

    /// Plays the timeline range `[start, end]` at `speed` (splitting clips at its edges).
    static func setSpeed(_ speed: Double, from start: Double, to end: Double, in content: EditContent, project: Project) -> EditContent {
        let before = place(content, project)
        var result = split(content, at: [start, end], project: project)
        let splitPlacements = place(result, project)
        var lineage: [UUID: UUID] = [:]
        // Pieces created by the split map back to the clip they came from, via source time.
        for p in splitPlacements {
            lineage[p.clip.id] = before.first { $0.clip.source == p.clip.source && $0.clip.start <= p.clip.start + 0.001
                && $0.clip.end >= p.clip.end - 0.001 }?.clip.id ?? p.clip.id
        }
        for p in splitPlacements where p.offset >= start - 0.02 && p.end <= end + 0.02 {
            result.clips[p.index].speed = speed
        }
        return remap(result, from: before, lineage: lineage, project: project)
    }

    /// Moves timeline-time items from the old layout to the new one, following the source time
    /// they sat on. Items on removed content land at the cut.
    private static func remap(_ content: EditContent, from before: [ClipPlacement], lineage: [UUID: UUID], project: Project) -> EditContent {
        let after = place(content, project)
        func map(_ t: Double) -> Double {
            guard let old = before.last(where: { $0.offset <= t }) ?? before.first else { return t }
            let s = old.sourceTime(min(t, old.end))
            let pieces = after.filter { (lineage[$0.clip.id] ?? $0.clip.id) == old.clip.id }
            if let piece = pieces.first(where: { s >= $0.clip.start - 0.001 && s <= $0.clip.end + 0.001 }) {
                return piece.timelineTime(s)
            }
            if let next = pieces.first(where: { $0.clip.start > s }) { return next.offset }
            if let last = pieces.last { return last.end }
            // The whole clip is gone: land where the next surviving clip starts.
            let survivors = Set(after.map { lineage[$0.clip.id] ?? $0.clip.id })
            if let nextOld = before.first(where: { $0.offset > old.offset && survivors.contains($0.clip.id) }),
               let piece = after.first(where: { (lineage[$0.clip.id] ?? $0.clip.id) == nextOld.clip.id }) {
                return piece.offset
            }
            return after.last?.end ?? 0
        }
        var result = content
        result.texts = content.texts.compactMap { text in
            var t = text
            t.start = map(text.start)
            t.end = map(text.end)
            return t.end - t.start >= 0.15 ? t : nil
        }
        result.cameraKeys = content.cameraKeys.map { var k = $0; k.t = map($0.t); return k }
        return result
    }

    static func merge(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var merged: [ClosedRange<Double>] = []
        for r in ranges.filter({ $0.upperBound > $0.lowerBound }).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, r.lowerBound <= last.upperBound + 0.02 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    private static func place(_ content: EditContent, _ project: Project) -> [ClipPlacement] {
        TimelineLayout.place(content.clips, in: project)
    }
}
