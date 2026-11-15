import CoreImage
import Foundation
import Vision

/// Everything needed to draw any frame of one clip with one set of settings. Built whenever the
/// edit changes, then read-only from the compositor's render threads.
final class RenderModel: @unchecked Sendable {
    struct Sprite {
        let image: CIImage
        let width: Double   // points
        let height: Double  // points
        let hotX: Double
        let hotY: Double
    }

    let clipID: UUID
    let canvas: CGSize
    let videoRect: CGRect
    let source: CGSize
    /// Source time = clipStart + (composition time - clipOffset) * speed.
    let clipOffset: Double
    let clipStart: Double
    let speed: Double

    private let backdrop: CIImage
    private let mask: CIImage
    private let settings: EditSettings
    private let pointScale: Double
    private let cursor: Track
    private let camera: Track
    private let mouse: [MouseSample]
    private let clicks: [ClickEvent]
    private let sprites: [String: Sprite]
    private let cameraLayout: Clip.CameraLayout
    private let bubble: Bubble?
    private let unit: Double
    private let preview: Bool
    /// Camera-only render: the camera full frame, black where the clip has none.
    private let cameraOnly: Bool
    private let isCard: Bool
    /// Split layout: the screen part, rendered by its own model on its own (smaller) canvas, and
    /// where the screen and camera parts sit in the output.
    private let splitScreen: RenderModel?
    private let splitScreenRect: CGRect
    private let splitCameraRect: CGRect
    private let blurs: [BlurRegion]
    /// Face centre (x, y) and size in camera-file time, spring-smoothed.
    private let faceTrack: Track?
    private let webcamOffset: Double
    private let follow: Bool

    /// The webcam picture-in-picture: its placement plus a mask and shadow drawn once at the origin
    /// and moved into place per frame.
    private struct Bubble {
        let placement: CameraPlacement
        let mask: CIImage
        let shadow: CIImage
        let shadowPad: CGFloat
    }

    /// Where the camera bubble is at any moment, and how visible each layout is. Camera-lane
    /// keyframes win; without them the bubble follows the path it was dragged along while
    /// recording (spring-smoothed) or sits at a fixed spot (dragged in the editor, or a corner).
    /// Positions carry across clips; layouts don't: each clip starts in its own layout and
    /// keyframes inside it change that mid-clip. Shared with the editor, which hit-tests the
    /// bubble for dragging.
    struct CameraPlacement {
        let size: CGSize
        let canvas: CGSize
        let margin: CGFloat
        let fixedCenter: CGPoint
        let path: Track?
        let keys: [CameraKey]
        let baseLayout: Clip.CameraLayout
        /// Timeline time the clip starts; layout keys before it belong to earlier clips.
        let clipStart: Double

        static let moveDuration = 0.5
        static let layoutFade = 0.35

        init(settings: EditSettings, info: RecordingInfo, canvas: CGSize, videoRect: CGRect,
             keys: [CameraKey] = [], baseLayout: Clip.CameraLayout = .overlay, clipStart: Double = -.infinity) {
            let unit = min(canvas.width, canvas.height) / 1080
            let height = (settings.cameraSize * canvas.height).rounded()
            size = CGSize(width: (height * settings.cameraShape.aspect).rounded(), height: height)
            self.canvas = canvas
            self.keys = keys.sorted { $0.t < $1.t }
            self.baseLayout = baseLayout
            self.clipStart = clipStart
            margin = 20 * unit
            if let x = settings.cameraX, let y = settings.cameraY {
                fixedCenter = CGPoint(x: x * canvas.width, y: (1 - y) * canvas.height)
            } else {
                let inset = 36 * unit
                let left = settings.cameraCorner == .topLeft || settings.cameraCorner == .bottomLeft
                let bottom = settings.cameraCorner == .bottomLeft || settings.cameraCorner == .bottomRight
                fixedCenter = CGPoint(x: left ? inset + size.width / 2 : canvas.width - inset - size.width / 2,
                                      y: bottom ? inset + size.height / 2 : canvas.height - inset - size.height / 2)
            }
            if settings.cameraFollowsRecording, let points = info.webcamPath, !points.isEmpty {
                let fps = 60.0, dt = 1 / fps
                let count = Int(info.duration * fps) + 2
                var xs = [Double](repeating: 0, count: count), ys = xs
                func target(_ p: WebcamPoint) -> CGPoint {
                    CGPoint(x: videoRect.minX + p.x * videoRect.width, y: videoRect.maxY - p.y * videoRect.height)
                }
                var x = Double(target(points[0]).x), y = Double(target(points[0]).y), vx = 0.0, vy = 0.0
                var index = 0
                for i in 0..<count {
                    let t = Double(i) * dt
                    while index + 1 < points.count, points[index + 1].t <= t { index += 1 }
                    let goal = target(points[index])
                    Spring.camera.step(value: &x, velocity: &vx, target: goal.x, dt: dt)
                    Spring.camera.step(value: &y, velocity: &vy, target: goal.y, dt: dt)
                    xs[i] = x
                    ys[i] = y
                }
                path = Track(fps: fps, channels: [xs, ys])
            } else {
                path = nil
            }
        }

        private func baseCenter(_ t: Double) -> CGPoint {
            path.map { CGPoint(x: $0.value(0, at: t), y: $0.value(1, at: t)) } ?? fixedCenter
        }

        private func keyCenter(_ key: CameraKey) -> CGPoint {
            CGPoint(x: key.x * canvas.width, y: (1 - key.y) * canvas.height)
        }

        /// Bubble rect plus how much of the overlay / fullscreen / split layout shows, at source
        /// time `t` and timeline time `time`.
        func state(source t: Double, timeline time: Double) -> (rect: CGRect, overlay: Double, fullscreen: Double, split: Double) {
            func weight(_ layout: Clip.CameraLayout) -> (Double, Double, Double) {
                (layout == .overlay ? 1 : 0, layout == .fullscreen ? 1 : 0, layout == .split ? 1 : 0)
            }
            var center = baseCenter(t)
            var (overlay, fullscreen, split) = weight(baseLayout)
            if let index = keys.lastIndex(where: { $0.t <= time }) {
                let key = keys[index]
                let from = index > 0 ? keyCenter(keys[index - 1]) : baseCenter(t)
                let p = min(1, (time - key.t) / Self.moveDuration)
                let e = p * p * (3 - 2 * p)
                let to = keyCenter(key)
                center = CGPoint(x: from.x + (to.x - from.x) * e, y: from.y + (to.y - from.y) * e)
                if key.t >= clipStart {
                    let previous = index > 0 && keys[index - 1].t >= clipStart ? keys[index - 1].layout ?? .overlay : baseLayout
                    let a = weight(previous)
                    let b = weight(key.layout ?? .overlay)
                    let m = min(1, (time - key.t) / Self.layoutFade)
                    overlay = a.0 + (b.0 - a.0) * m
                    fullscreen = a.1 + (b.1 - a.1) * m
                    split = a.2 + (b.2 - a.2) * m
                }
            }
            let x = min(max(center.x - size.width / 2, margin), canvas.width - margin - size.width)
            let y = min(max(center.y - size.height / 2, margin), canvas.height - margin - size.height)
            return (CGRect(origin: CGPoint(x: x, y: y), size: size), overlay, fullscreen, split)
        }
    }

    init(media: ClipMedia, settings: EditSettings, clip: Clip, canvas: CGSize, clipStart: Double, clipOffset: Double,
         cameraKeys: [CameraKey] = [], blurs: [BlurRegion] = [], preview: Bool = false, cameraOnly: Bool = false) {
        let info = media.info
        let zooms = clip.zooms
        var settings = settings
        if clip.isCard == true {
            // Brand cards fill the frame: no padding, corners, shadow, cursor or camera.
            settings.padding = 0
            settings.cornerRadius = 0
            settings.shadow = 0
            settings.showCursor = false
            settings.showCamera = false
            settings.reframe = false
        }
        self.clipID = clip.id
        self.settings = settings
        self.preview = preview
        self.cameraOnly = cameraOnly
        self.isCard = clip.isCard == true
        self.blurs = blurs.filter { $0.enabled && $0.source == clip.source }
        self.webcamOffset = info.webcam?.offset ?? 0
        if settings.centerFace, let webcam = info.webcam,
           let points = FaceTracker.cached(for: media.folder.appendingPathComponent(webcam.file)), !points.isEmpty {
            self.faceTrack = Self.faceTrack(points)
        } else {
            self.faceTrack = nil
        }
        self.source = media.sourceSize
        self.pointScale = info.pointScale
        self.clipStart = clipStart
        self.clipOffset = clipOffset
        self.speed = clip.speed
        self.cameraLayout = settings.showCamera ? clip.camera : .hidden
        self.mouse = info.mouse
        self.clicks = info.clicks.sorted { $0.t < $1.t }

        self.canvas = canvas
        let card = clip.isCard == true
        let videoRect = card
            ? CGRect(origin: .zero, size: canvas)
            : Self.videoRect(canvas: canvas, source: source, settings: settings)
        self.videoRect = videoRect
        self.follow = Self.fills(settings)
        let unit = min(canvas.width, canvas.height) / 1080
        self.unit = unit
        self.bubble = info.webcam == nil ? nil : Self.makeBubble(
            CameraPlacement(settings: settings, info: info, canvas: canvas, videoRect: videoRect,
                            keys: settings.showCamera ? cameraKeys : [], baseLayout: settings.showCamera ? clip.camera : .hidden,
                            clipStart: clipOffset),
            settings: settings, unit: unit)

        let pointToCanvas = info.pointScale * videoRect.width / source.width
        let radius = max(settings.padding > 0.001 ? settings.cornerRadius * unit : 0,
                         (info.cornerRadius ?? 0) * pointToCanvas)
        (backdrop, mask) = Backdrop.make(canvas: canvas, videoRect: videoRect, radius: radius, unit: unit, settings: settings)

        var sprites: [String: Sprite] = [:]
        for c in info.cursors {
            guard let image = CIImage(contentsOf: media.cursorsURL.appendingPathComponent("\(c.id).png")),
                  image.extent.width > 0 else { continue }
            // Height follows the PNG's aspect so imported cursors with odd "standard sizes" don't stretch.
            let height = c.width * image.extent.height / image.extent.width
            sprites[c.id] = Sprite(image: image, width: c.width, height: height, hotX: c.hotX, hotY: c.hotY)
        }
        self.sprites = sprites

        let cursor = Motion.cursorTrack(info, smooth: settings.smoothCursor)
        self.cursor = cursor
        self.camera = Self.cameraTrack(info: info, settings: settings, zooms: zooms,
                                       cursor: cursor, canvas: canvas, videoRect: videoRect, follow: Self.fills(settings))

        (splitScreenRect, splitCameraRect) = Self.splitRects(canvas: canvas, ratio: settings.splitRatio)
        let usesSplit = settings.showCamera && info.webcam != nil && !card && !cameraOnly
            && (clip.camera == .split || cameraKeys.contains { $0.layout == .split && $0.t >= clipOffset })
        if usesSplit {
            // The screen part fills its area and follows the cursor, like a vertical reframe.
            var screen = settings
            screen.showCamera = false
            screen.reframe = true
            screen.aspect = .vertical
            screen.padding = 0
            screen.cornerRadius = 0
            screen.shadow = 0
            self.splitScreen = RenderModel(media: media, settings: screen, clip: clip, canvas: splitScreenRect.size,
                                           clipStart: clipStart, clipOffset: clipOffset, blurs: blurs, preview: preview)
        } else {
            self.splitScreen = nil
        }
    }

    /// Split layout areas (Core Image coordinates): a vertical frame stacks the screen (top 58% by
    /// default) over the camera; a landscape or square one puts the screen left (62%) and the camera right.
    static func splitRects(canvas: CGSize, ratio: Double? = nil) -> (screen: CGRect, camera: CGRect) {
        func even(_ v: CGFloat) -> CGFloat { CGFloat(Int(v.rounded()) & ~1) }
        if canvas.height > canvas.width {
            let top = even(canvas.height * min(0.8, max(0.3, ratio ?? 0.58)))
            return (CGRect(x: 0, y: canvas.height - top, width: canvas.width, height: top),
                    CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height - top))
        }
        let left = even(canvas.width * min(0.8, max(0.3, ratio ?? 0.62)))
        return (CGRect(x: 0, y: 0, width: left, height: canvas.height),
                CGRect(x: left, y: 0, width: canvas.width - left, height: canvas.height))
    }

    /// Vertical/square output with "fill & follow": the recording covers the frame and the camera
    /// tracks the cursor.
    static func fills(_ settings: EditSettings) -> Bool { settings.reframe && settings.aspect != .source }

    /// Where the recording sits in the canvas: fitted inside the padding, or covering it (fill).
    static func videoRect(canvas: CGSize, source: CGSize, settings: EditSettings) -> CGRect {
        guard fills(settings) else { return videoRect(canvas: canvas, source: source, padding: settings.padding) }
        let pad = settings.padding * min(canvas.width, canvas.height) * 0.5
        let available = CGSize(width: canvas.width - 2 * pad, height: canvas.height - 2 * pad)
        let cover = max(available.width / source.width, available.height / source.height)
        let size = CGSize(width: source.width * cover, height: source.height * cover)
        return CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2, width: size.width, height: size.height)
    }

    private static func faceTrack(_ points: [FaceTracker.Point]) -> Track {
        let fps = 30.0, dt = 1 / fps
        let count = Int((points.last?.t ?? 0) * fps) + 2
        var xs = [Double](repeating: 0.5, count: count), ys = xs, sizes = [Double](repeating: 0.3, count: count)
        var x = points[0].x, y = points[0].y, size = points[0].size, vx = 0.0, vy = 0.0, vs = 0.0
        var index = 0
        for i in 0..<count {
            let t = Double(i) * dt
            while index + 1 < points.count, points[index + 1].t <= t { index += 1 }
            let p = points[index]
            Spring.camera.step(value: &x, velocity: &vx, target: p.x, dt: dt)
            Spring.camera.step(value: &y, velocity: &vy, target: p.y, dt: dt)
            Spring.camera.step(value: &size, velocity: &vs, target: p.size, dt: dt)
            xs[i] = x
            ys[i] = y
            sizes[i] = size
        }
        return Track(fps: fps, channels: [xs, ys, sizes])
    }

    static func videoRect(canvas: CGSize, source: CGSize, padding: Double) -> CGRect {
        let pad = padding * min(canvas.width, canvas.height)
        let available = CGRect(x: pad, y: pad, width: canvas.width - 2 * pad, height: canvas.height - 2 * pad)
        let fit = min(available.width / source.width, available.height / source.height)
        let size = CGSize(width: source.width * fit, height: source.height * fit)
        return CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// Output canvas and where the (padded) screen recording sits inside it.
    static func layout(source: CGSize, settings: EditSettings, resolution: ExportResolution?,
                       maxLongSide: CGFloat?) -> (canvas: CGSize, videoRect: CGRect) {
        let canvas = canvasSize(source: source, aspect: settings.aspect, resolution: resolution, maxLongSide: maxLongSide)
        return (canvas, videoRect(canvas: canvas, source: source, padding: settings.padding))
    }

    /// Share of the recording (width, height) that is visible at a zoom level, once the camera has
    /// settled inside the screen content.
    static func visibleFraction(zoom: Double, canvas: CGSize, videoRect: CGRect) -> CGSize {
        CGSize(width: min(1, canvas.width / zoom / videoRect.width), height: min(1, canvas.height / zoom / videoRect.height))
    }

    static func canvasSize(source: CGSize, aspect: AspectChoice, resolution: ExportResolution?, maxLongSide: CGFloat?) -> CGSize {
        var w = source.width, h = source.height
        if let ratio = aspect.ratio {
            if ratio >= w / h { w = h * ratio } else { h = w / ratio }
        }
        var scale: CGFloat = 1
        switch resolution {
        case .p1080?: scale = 1080 / min(w, h)
        case .p2160?: scale = 2160 / min(w, h)
        case .native?, nil: break
        }
        // H.264 tops out around 4096 px; keep a margin.
        scale = min(scale, 3840 / max(w, h))
        if let maxLongSide { scale = min(scale, maxLongSide / max(w, h)) }
        return CGSize(width: CGFloat(Int(w * scale) & ~1), height: CGFloat(Int(h * scale) & ~1))
    }

    // MARK: Camera

    /// Zoom (channel 0) and camera centre (1, 2) in canvas coordinates. While a zoom segment is
    /// active the camera springs toward its focus (the cursor, or a fixed point), otherwise back to
    /// the full frame.
    private static func cameraTrack(info: RecordingInfo, settings: EditSettings, zooms: [ZoomSegment],
                                    cursor: Track, canvas: CGSize, videoRect: CGRect, follow: Bool) -> Track {
        let fps = 120.0, dt = 1 / fps
        let count = Int(info.duration * fps) + 2
        var scales = [Double](repeating: 1, count: count)
        var xs = [Double](repeating: canvas.width / 2, count: count), ys = [Double](repeating: canvas.height / 2, count: count)
        let active = settings.autoZoom ? zooms.filter(\.enabled).sorted { $0.start < $1.start } : []
        let source = CGSize(width: info.sourceWidth, height: info.sourceHeight)
        let hasCursor = !info.mouse.isEmpty
        guard !active.isEmpty || (follow && hasCursor) else { return Track(fps: fps, channels: [scales, xs, ys]) }

        let canvasRect = CGRect(origin: .zero, size: canvas)
        var s = 1.0, vs = 0.0
        var cx = Double(canvas.width / 2), cy = Double(canvas.height / 2), vx = 0.0, vy = 0.0
        for i in 0..<count {
            let t = Double(i) * dt
            var targetScale = 1.0, tx = Double(canvas.width / 2), ty = Double(canvas.height / 2)
            if follow, hasCursor {
                let p = canvasPoint(x: cursor.value(0, at: t), y: cursor.value(1, at: t), source: source, videoRect: videoRect)
                tx = p.x
                ty = p.y
            }
            if let segment = active.first(where: { t >= $0.start && t < $0.end }) {
                targetScale = segment.zoom
                let focus = segment.focus.map { (x: $0.x * info.sourceWidth, y: $0.y * info.sourceHeight) }
                    ?? (x: cursor.value(0, at: t), y: cursor.value(1, at: t))
                let p = canvasPoint(x: focus.x, y: focus.y, source: CGSize(width: info.sourceWidth, height: info.sourceHeight),
                                    videoRect: videoRect)
                tx = p.x
                ty = p.y
            }
            if i == 0, follow { cx = tx; cy = ty }
            Spring.camera.step(value: &s, velocity: &vs, target: targetScale, dt: dt)
            Spring.camera.step(value: &cx, velocity: &vx, target: tx, dt: dt)
            Spring.camera.step(value: &cy, velocity: &vy, target: ty, dt: dt)

            // Keep the view on the screen content: the allowed area shrinks from the whole canvas
            // to the video rect as the zoom grows, so the background slides out of view.
            let scale = max(1, s)
            let progress = follow ? 1 : min(1, (scale - 1) / 0.35)
            let bounds = lerp(canvasRect, videoRect, progress)
            let hw = canvas.width / (2 * scale), hh = canvas.height / (2 * scale)
            var x = bounds.width >= 2 * hw ? min(max(cx, bounds.minX + hw), bounds.maxX - hw) : bounds.midX
            var y = bounds.height >= 2 * hh ? min(max(cy, bounds.minY + hh), bounds.maxY - hh) : bounds.midY
            x = min(max(x, hw), canvas.width - hw)
            y = min(max(y, hh), canvas.height - hh)
            scales[i] = scale
            xs[i] = x
            ys[i] = y
        }
        return Track(fps: fps, channels: [scales, xs, ys])
    }

    private static func lerp(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }

    /// Source pixels (top-left origin) → canvas (bottom-left origin, Core Image convention).
    private static func canvasPoint(x: Double, y: Double, source: CGSize, videoRect: CGRect) -> CGPoint {
        CGPoint(x: videoRect.minX + x / source.width * videoRect.width,
                y: videoRect.maxY - y / source.height * videoRect.height)
    }

    // MARK: Frame

    /// `time` is composition (timeline) time. `frame` is nil where the clip's video has no frame.
    func render(source frame: CIImage?, webcam: CIImage?, time: Double) -> CIImage {
        let t = clipStart + (time - clipOffset) * speed
        let bounds = CGRect(origin: .zero, size: canvas)
        let black = CIImage(color: .black).cropped(to: bounds)
        if cameraOnly {
            // Brand cards and clips without a camera stay black.
            guard !isCard, let webcam else { return black }
            return fullscreenCamera(prepareWebcam(webcam, t: t), t: t).cropped(to: bounds).composited(over: black)
        }
        let cam = bubble.map { $0.placement.state(source: t, timeline: time) }
        let fullscreen = webcam == nil ? 0 : cam?.fullscreen ?? (cameraLayout == .fullscreen ? 1 : 0)
        let split = webcam == nil || splitScreen == nil ? 0 : cam?.split ?? (cameraLayout == .split ? 1 : 0)
        let picture = webcam.map { prepareWebcam($0, t: t) }

        if fullscreen > 0.999, let picture {
            return fullscreenCamera(picture, t: t).cropped(to: bounds).composited(over: black)
        }
        let splitImage = split > 0.001 ? picture.map { splitFrame(source: frame, camera: $0, time: time, t: t) } : nil
        if split > 0.999, let splitImage { return splitImage }

        var image = backdrop
        if var frame {
            frame = applyBlurs(to: frame, t: t)
            let extent = frame.extent
            let placed = frame
                .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                .transformed(by: CGAffineTransform(scaleX: videoRect.width / extent.width, y: videoRect.height / extent.height))
                .transformed(by: CGAffineTransform(translationX: videoRect.minX, y: videoRect.minY))
            image = placed.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: backdrop,
                kCIInputMaskImageKey: mask,
            ])
        }

        let scale = camera.value(0, at: t)
        if settings.showCursor {
            if settings.clickEffect { image = drawRipples(on: image, t: t) }
            image = drawCursor(on: image, t: t, cameraScale: scale)
        }

        let cx = camera.value(1, at: t), cy = camera.value(2, at: t)
        if scale > 1.0005 || abs(cx - canvas.width / 2) > 0.5 || abs(cy - canvas.height / 2) > 0.5 {
            image = image
                .transformed(by: CGAffineTransform(translationX: -cx, y: -cy))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: canvas.width / 2, y: canvas.height / 2))
        }
        image = image.cropped(to: bounds)
        image = cameraBlur(image, t: t, scale: scale)

        if let picture, let bubble, let cam, cam.overlay > 0.001 {
            let rect = cam.rect
            let mask = bubble.mask.transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
            var inBubble = fill(picture, into: rect, face: true, t: t)
                .cropped(to: rect)
                .applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: rect),
                    kCIInputMaskImageKey: mask,
                ])
            if settings.cameraBackground != .remove {
                let shadow = bubble.shadow.transformed(by: CGAffineTransform(translationX: rect.minX - bubble.shadowPad,
                                                                             y: rect.minY - bubble.shadowPad))
                inBubble = inBubble.composited(over: shadow)
            }
            image = faded(inBubble, cam.overlay).composited(over: image)
        }
        if fullscreen > 0.001, let picture {
            image = faded(fullscreenCamera(picture, t: t).cropped(to: bounds), fullscreen).composited(over: image)
        }
        if let splitImage { image = faded(splitImage, split).composited(over: image) }
        return image.composited(over: black)
    }

    /// Split layout: the screen part (its own model: fill, follow, zooms, cursor) in its area and the
    /// face-centred camera in the other.
    private func splitFrame(source frame: CIImage?, camera picture: CIImage, time: Double, t: Double) -> CIImage {
        let bounds = CGRect(origin: .zero, size: canvas)
        let black = CIImage(color: .black).cropped(to: bounds)
        var image = black
        if let splitScreen {
            let screen = splitScreen.render(source: frame, webcam: nil, time: time)
                .cropped(to: CGRect(origin: .zero, size: splitScreenRect.size))
                .transformed(by: CGAffineTransform(translationX: splitScreenRect.minX, y: splitScreenRect.minY))
            image = screen.composited(over: image)
        }
        var face = fill(picture, into: splitCameraRect, face: true, t: t).cropped(to: splitCameraRect)
        if settings.cameraBackground == .remove { face = face.composited(over: backdrop.cropped(to: splitCameraRect)) }
        image = face.composited(over: image)
        if let divider = settings.splitDivider {
            let w = max(1, (divider.width * min(canvas.width, canvas.height)).rounded())
            let vertical = splitScreenRect.minY > splitCameraRect.minY
            let line = vertical
                ? CGRect(x: 0, y: splitScreenRect.minY - w / 2, width: canvas.width, height: w)
                : CGRect(x: splitScreenRect.maxX - w / 2, y: 0, width: w, height: canvas.height)
            image = CIImage(color: CIColor(cgColor: .hex(divider.color))).cropped(to: line).composited(over: image)
        }
        return image
    }

    private func faded(_ image: CIImage, _ alpha: Double) -> CIImage {
        alpha >= 0.999 ? image : image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)])
    }

    /// Full-frame camera; with the background removed, over the project background.
    private func fullscreenCamera(_ camera: CIImage, t: Double) -> CIImage {
        let bounds = CGRect(origin: .zero, size: canvas)
        let picture = fill(camera, into: bounds, face: false, t: t).cropped(to: bounds)
        return settings.cameraBackground == .remove ? picture.composited(over: backdrop) : picture
    }

    // MARK: Privacy blur

    /// Where a source rect (normalized, top-left origin) shows in the output at timeline `time`,
    /// zoom and pan included. Output canvas coordinates, bottom-left origin.
    func outputRect(forSource r: CGRect, time: Double) -> CGRect {
        let t = clipStart + (time - clipOffset) * speed
        if let splitScreen, let state = bubble?.placement.state(source: t, timeline: time), state.split > 0.5 {
            return splitScreen.outputRect(forSource: r, time: time)
                .offsetBy(dx: splitScreenRect.minX, dy: splitScreenRect.minY)
                .intersection(splitScreenRect)
        }
        let placed = CGRect(x: videoRect.minX + r.minX * videoRect.width, y: videoRect.maxY - r.maxY * videoRect.height,
                            width: r.width * videoRect.width, height: r.height * videoRect.height)
        return placed.applying(cameraTransform(at: t))
    }

    /// Output pixels per normalized source unit at timeline `time` (for dragging on the preview).
    func outputScale(time: Double) -> CGSize {
        let s = camera.value(0, at: clipStart + (time - clipOffset) * speed)
        return CGSize(width: videoRect.width * s, height: videoRect.height * s)
    }

    private func cameraTransform(at t: Double) -> CGAffineTransform {
        let s = camera.value(0, at: t), cx = camera.value(1, at: t), cy = camera.value(2, at: t)
        return CGAffineTransform(translationX: -cx, y: -cy)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: canvas.width / 2, y: canvas.height / 2))
    }

    private func applyBlurs(to frame: CIImage, t: Double) -> CIImage {
        let active = blurs.filter { t >= $0.start && t < $0.end }
        guard !active.isEmpty else { return frame }
        let e = frame.extent
        var result = frame
        for region in active {
            let rect = CGRect(x: e.minX + region.x * e.width, y: e.minY + (1 - region.y - region.h) * e.height,
                              width: region.w * e.width, height: region.h * e.height).intersection(e)
            guard !rect.isNull, rect.width > 1, rect.height > 1 else { continue }
            // Blur first so each pixel cell takes the average colour (pixellate alone point-samples
            // and leaves thin text legible), pixelate, then soften the blocks.
            let cell = max(10, min(rect.width, rect.height) * 0.5)
            let blurred = frame.cropped(to: rect).clampedToExtent()
                .applyingGaussianBlur(sigma: cell * 0.6)
                .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: cell,
                                                            kCIInputCenterKey: CIVector(x: rect.minX, y: rect.minY)])
                .applyingGaussianBlur(sigma: cell * 0.2)
                .cropped(to: rect)
                .settingAlphaOne(in: rect)
            result = blurred.composited(over: result)
        }
        return result
    }

    // MARK: Webcam

    private static func makeBubble(_ placement: CameraPlacement, settings: EditSettings, unit: Double) -> Bubble {
        let rect = CGRect(origin: .zero, size: placement.size)
        let radius = settings.cameraShape == .circle ? rect.height / 2 : rect.height * 0.16
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        let maskCtx = CGContext(data: nil, width: Int(rect.width), height: Int(rect.height), bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        maskCtx.addPath(path)
        maskCtx.setFillColor(gray: 1, alpha: 1)
        maskCtx.fillPath()

        let pad = 60 * unit
        let shadowCtx = CGContext(data: nil, width: Int(rect.width + 2 * pad), height: Int(rect.height + 2 * pad), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: Backdrop.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        shadowCtx.translateBy(x: pad, y: pad)
        shadowCtx.setShadow(offset: CGSize(width: 0, height: -10 * unit), blur: 30 * unit, color: CGColor(gray: 0, alpha: 0.45))
        shadowCtx.addPath(path)
        shadowCtx.setFillColor(CGColor(gray: 0, alpha: 1))
        shadowCtx.fillPath()

        return Bubble(placement: placement, mask: CIImage(cgImage: maskCtx.makeImage()!),
                      shadow: CIImage(cgImage: shadowCtx.makeImage()!), shadowPad: pad)
    }

    private func mirrored(_ image: CIImage) -> CIImage {
        guard settings.mirrorCamera else { return image }
        let e = image.extent
        return image.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: e.minX + e.maxX, ty: 0))
    }

    /// Background treatment (person segmentation, on-device) then mirroring.
    private func prepareWebcam(_ image: CIImage, t: Double) -> CIImage {
        var picture = image
        if settings.cameraBackground != .none {
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = preview ? .fast : .balanced
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            let e = image.extent
            if (try? VNImageRequestHandler(ciImage: image).perform([request])) != nil,
               let buffer = request.results?.first?.pixelBuffer {
                let raw = CIImage(cvPixelBuffer: buffer)
                let mask = raw.transformed(by: CGAffineTransform(scaleX: e.width / raw.extent.width, y: e.height / raw.extent.height))
                    .transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
                let background = settings.cameraBackground == .blur
                    ? image.clampedToExtent().applyingGaussianBlur(sigma: 22).cropped(to: e)
                    : CIImage(color: .clear).cropped(to: e)
                picture = image.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: mask,
                ])
            }
        }
        return mirrored(picture)
    }

    /// Covers `rect` with the camera picture. With face centring on, the face (tracked on-device)
    /// moves to the middle and, in the bubble, is framed to about half its height.
    private func fill(_ image: CIImage, into rect: CGRect, face: Bool, t: Double) -> CIImage {
        let e = image.extent
        let cover = max(rect.width / e.width, rect.height / e.height)
        guard let faceTrack else {
            return image
                .transformed(by: CGAffineTransform(translationX: -e.midX, y: -e.midY))
                .transformed(by: CGAffineTransform(scaleX: cover, y: cover))
                .transformed(by: CGAffineTransform(translationX: rect.midX, y: rect.midY))
        }
        let ft = t - webcamOffset
        var fx = faceTrack.value(0, at: ft), fy = faceTrack.value(1, at: ft)
        if settings.mirrorCamera { fx = 1 - fx }
        let size = faceTrack.value(2, at: ft)
        let scale = face ? min(cover * 2.2, max(cover, 0.5 * rect.height / max(0.05, size * e.height))) : cover
        // Face point in image coordinates (bottom-left origin) → rect centre, then keep covered.
        let px = e.minX + fx * e.width, py = e.minY + (1 - fy) * e.height
        var tx = rect.midX - px * scale, ty = rect.midY - py * scale
        tx = min(max(tx, rect.maxX - e.maxX * scale), rect.minX - e.minX * scale)
        ty = min(max(ty, rect.maxY - e.maxY * scale), rect.minY - e.minY * scale)
        return image.transformed(by: CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: tx, ty: ty))
    }

    // MARK: Motion blur

    /// Blurs the frame along fast camera pans and zooms: a quarter-frame shutter at 60 fps, measured
    /// over ±1/30 s so spring jitter doesn't register, and only once the smear would be visible.
    private func cameraBlur(_ image: CIImage, t: Double, scale: Double) -> CIImage {
        guard settings.motionBlur > 0.01 else { return image }
        let dt = 1.0 / 30
        let s0 = camera.value(0, at: t - dt), s1 = camera.value(0, at: t + dt)
        let vx = (camera.value(1, at: t + dt) - camera.value(1, at: t - dt)) / (2 * dt) * scale * speed
        let vy = (camera.value(2, at: t + dt) - camera.value(2, at: t - dt)) / (2 * dt) * scale * speed
        let zoomRate = abs(s1 - s0) / (2 * dt) / max(scale, 1) * speed
        let shutter = 0.25 / 60 * settings.motionBlur
        var result = image
        let bounds = CGRect(origin: .zero, size: canvas)

        let pan = min(7 * unit, hypot(vx, vy) * shutter)
        if pan > 2.5 * unit {
            result = result.clampedToExtent()
                .applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: pan, kCIInputAngleKey: atan2(-vy, -vx)])
                .cropped(to: bounds)
        }
        let zoom = min(5 * unit, zoomRate * hypot(canvas.width, canvas.height) / 2 * shutter)
        if zoom > 2.5 * unit {
            result = result.clampedToExtent()
                .applyingFilter("CIZoomBlur", parameters: [kCIInputCenterKey: CIVector(x: canvas.width / 2, y: canvas.height / 2),
                                                           "inputAmount": zoom])
                .cropped(to: bounds)
        }
        return result
    }

    /// Canvas pixels per screen point.
    private var pointToCanvas: Double { pointScale * videoRect.width / source.width }

    private func drawCursor(on image: CIImage, t: Double, cameraScale: Double) -> CIImage {
        guard let i = Motion.lastIndex(mouse, atOrBefore: t, time: { $0.t }) ?? (mouse.isEmpty ? nil : 0),
              let id = mouse[i].c, let sprite = sprites[id] else { return image }
        let x = cursor.value(0, at: t), y = cursor.value(1, at: t)
        let margin = 0.02 * source.width
        guard x > -margin, y > -margin, x < source.width + margin, y < source.height + margin else { return image }

        let p = Self.canvasPoint(x: x, y: y, source: source, videoRect: videoRect)
        let k = pointToCanvas * settings.cursorScale * (1 - 0.15 * pressAmount(t))
        let f = sprite.width * k / sprite.image.extent.width
        let origin = CGPoint(x: p.x - sprite.hotX * k, y: p.y - (sprite.height - sprite.hotY) * k)
        var cursorImage = sprite.image
            .transformed(by: CGAffineTransform(translationX: -sprite.image.extent.minX, y: -sprite.image.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: f, y: f))
            .transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))

        if settings.motionBlur > 0.01 {
            // Velocity in output pixels per second; blur over half a 60 fps frame.
            let dt = 1.0 / 60
            let toCanvas = videoRect.width / source.width * cameraScale * speed
            let vx = (cursor.value(0, at: t + dt) - cursor.value(0, at: t - dt)) / (2 * dt) * toCanvas
            let vy = (cursor.value(1, at: t + dt) - cursor.value(1, at: t - dt)) / (2 * dt) * toCanvas
            let radius = min(20 * unit, hypot(vx, vy) * 0.35 / 60 * settings.motionBlur)
            if radius > 1.5 * unit {
                let extent = cursorImage.extent.insetBy(dx: -radius * 2, dy: -radius * 2)
                cursorImage = cursorImage
                    .applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: radius, kCIInputAngleKey: atan2(-vy, vx)])
                    .cropped(to: extent)
            }
        }
        return cursorImage.composited(over: image)
    }

    /// 0 → released, 1 → fully pressed; eases in over 70 ms and out over 150 ms.
    private func pressAmount(_ t: Double) -> Double {
        guard let i = Motion.lastIndex(clicks, atOrBefore: t, time: { $0.t }) else { return 0 }
        let event = clicks[i]
        return event.down ? min(1, (t - event.t) / 0.07) : max(0, 1 - (t - event.t) / 0.15)
    }

    private func drawRipples(on image: CIImage, t: Double) -> CIImage {
        let duration = 0.5
        var result = image
        for click in clicks where click.down && click.t <= t && t - click.t < duration {
            let p = (t - click.t) / duration
            let eased = 1 - pow(1 - p, 3)
            let radius = (10 + 26 * eased) * pointToCanvas * settings.cursorScale
            let alpha = 0.42 * pow(1 - p, 1.4)
            let center = Self.canvasPoint(x: click.x, y: click.y, source: source, videoRect: videoRect)
            let disc = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: center.x, y: center.y),
                "inputRadius0": radius * 0.6,
                "inputRadius1": radius,
                "inputColor0": CIColor(red: 0.25, green: 0.5, blue: 1, alpha: alpha),
                "inputColor1": CIColor(red: 0.25, green: 0.5, blue: 1, alpha: 0),
            ])?.outputImage?.cropped(to: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
            if let disc { result = disc.composited(over: result) }
        }
        return result
    }
}
