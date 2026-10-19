import Foundation

/// A clip as laid out on the timeline. Speed stretches a clip; a transition overlaps a clip with
/// the next one by the transition's duration.
struct ClipPlacement {
    let clip: Clip
    let index: Int
    let media: ClipMedia
    /// Timeline start and length.
    let offset: Double
    let duration: Double
    /// Overlap with the previous / next clip (transition time).
    let overlapIn: Double
    let overlapOut: Double

    var end: Double { offset + duration }
    var speed: Double { clip.speed }

    func sourceTime(_ t: Double) -> Double { clip.start + (t - offset) * speed }
    func timelineTime(_ s: Double) -> Double { offset + (s - clip.start) / speed }
}

enum TimelineLayout {
    static func place(_ clips: [Clip], in project: Project) -> [ClipPlacement] {
        var playable: [(clip: Clip, index: Int, media: ClipMedia, duration: Double)] = []
        for (index, clip) in clips.enumerated() {
            guard clip.duration > 0.05, let media = project.media(for: clip) else { continue }
            playable.append((clip, index, media, clip.duration / max(0.05, clip.speed)))
        }

        var result: [ClipPlacement] = []
        var offset = 0.0
        for (k, item) in playable.enumerated() {
            let overlapIn = k > 0 ? overlap(playable[k - 1].clip, playable[k - 1].duration, item.duration) : 0
            let overlapOut = k + 1 < playable.count ? overlap(item.clip, item.duration, playable[k + 1].duration) : 0
            if k > 0 { offset -= overlapIn }
            result.append(ClipPlacement(clip: item.clip, index: item.index, media: item.media, offset: offset,
                                        duration: item.duration, overlapIn: overlapIn, overlapOut: overlapOut))
            offset += item.duration
        }
        return result
    }

    /// A transition can use at most a third of either clip.
    private static func overlap(_ clip: Clip, _ duration: Double, _ nextDuration: Double) -> Double {
        guard let transition = clip.transition else { return 0 }
        return max(0, min(transition.duration, duration / 3, nextDuration / 3))
    }

    static func duration(of project: Project) -> Double {
        place(project.doc.clips, in: project).last?.end ?? 0
    }
}
