import Foundation

/// A damped spring, integrated in seconds. Constants follow Screen Studio's defaults.
struct Spring {
    var stiffness: Double
    var damping: Double
    var mass: Double

    static let cursor = Spring(stiffness: 470, damping: 70, mass: 3)
    static let camera = Spring(stiffness: 170, damping: 50, mass: 3)

    func step(value: inout Double, velocity: inout Double, target: Double, dt: Double) {
        let acceleration = (stiffness * (target - value) - damping * velocity) / mass
        velocity += acceleration * dt
        value += velocity * dt
    }
}

/// Values sampled on a fixed time grid, linearly interpolated on read.
struct Track {
    let fps: Double
    var channels: [[Double]]

    func value(_ channel: Int, at t: Double) -> Double {
        let values = channels[channel]
        guard !values.isEmpty else { return 0 }
        let position = max(0, t * fps)
        let i = min(values.count - 1, Int(position))
        let j = min(values.count - 1, i + 1)
        let f = position - Double(i)
        return values[i] + (values[j] - values[i]) * min(1, f)
    }
}

enum Motion {
    static let fps = 240.0

    /// Index of the last element whose time is <= t, or nil if t precedes everything.
    static func lastIndex<T>(_ items: [T], atOrBefore t: Double, time: (T) -> Double) -> Int? {
        var lo = 0, hi = items.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if time(items[mid]) <= t { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }

    /// Raw mouse position. Samples are only stored when the mouse moves, so short gaps are
    /// interpolated and long ones hold the previous position.
    static func rawCursor(_ mouse: [MouseSample], at t: Double) -> (x: Double, y: Double)? {
        guard !mouse.isEmpty else { return nil }
        guard let i = lastIndex(mouse, atOrBefore: t, time: { $0.t }) else { return (mouse[0].x, mouse[0].y) }
        let a = mouse[i]
        guard i + 1 < mouse.count else { return (a.x, a.y) }
        let b = mouse[i + 1]
        let gap = b.t - a.t
        guard gap > 0, gap < 0.05 else { return (a.x, a.y) }
        let f = (t - a.t) / gap
        return (a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f)
    }

    /// Cursor path in source pixels: channel 0 = x, 1 = y.
    static func cursorTrack(_ info: RecordingInfo, smooth: Bool) -> Track {
        let count = Int(info.duration * fps) + 2
        var xs = [Double](repeating: 0, count: count), ys = xs
        guard !info.mouse.isEmpty else { return Track(fps: fps, channels: [xs, ys]) }
        let dt = 1 / fps
        var x = info.mouse[0].x, y = info.mouse[0].y, vx = 0.0, vy = 0.0
        for i in 0..<count {
            let target = rawCursor(info.mouse, at: Double(i) * dt)!
            if smooth {
                Spring.cursor.step(value: &x, velocity: &vx, target: target.x, dt: dt)
                Spring.cursor.step(value: &y, velocity: &vy, target: target.y, dt: dt)
            } else {
                x = target.x
                y = target.y
            }
            xs[i] = x
            ys[i] = y
        }
        return Track(fps: fps, channels: [xs, ys])
    }
}
