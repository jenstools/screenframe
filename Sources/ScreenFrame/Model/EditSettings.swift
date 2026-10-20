import CoreGraphics
import Foundation

enum AspectChoice: String, Codable, CaseIterable, Identifiable {
    case source, wide, square, vertical, classic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .source: return "Source"
        case .wide: return "16:9"
        case .square: return "1:1"
        case .vertical: return "9:16"
        case .classic: return "4:3"
        }
    }

    var ratio: Double? {
        switch self {
        case .source: return nil
        case .wide: return 16.0 / 9.0
        case .square: return 1
        case .vertical: return 9.0 / 16.0
        case .classic: return 4.0 / 3.0
        }
    }
}

enum ExportResolution: String, Codable, CaseIterable, Identifiable {
    case p1080, p2160, native

    var id: String { rawValue }

    var label: String {
        switch self {
        case .p1080: return "1080p"
        case .p2160: return "4K"
        case .native: return "Native"
        }
    }
}

enum CameraShape: String, Codable, CaseIterable, Identifiable {
    case circle, rounded, wide
    var id: String { rawValue }
    var label: String {
        switch self {
        case .circle: return "Circle"
        case .rounded: return "Square"
        case .wide: return "16:9"
        }
    }
    /// Width / height of the bubble.
    var aspect: Double { self == .wide ? 16.0 / 9.0 : 1 }
}

struct Watermark: Codable, Equatable {
    /// Absolute path of the logo image.
    var path: String
    var corner = CameraCorner.topRight
    /// Logo height as a share of the output height.
    var size = 0.06
    var opacity = 0.9
}

enum CameraBackground: String, Codable, CaseIterable, Identifiable {
    case none, blur, remove
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "Original"
        case .blur: return "Blur"
        case .remove: return "Remove"
        }
    }
}

enum CameraCorner: String, Codable, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }
}

/// Every editor control. Decoding falls back to defaults per field so older project files keep
/// opening when settings are added.
struct EditSettings: Codable, Equatable {
    var background = "aurora"
    var backgroundBlur = 0.0
    var padding = 0.07
    var cornerRadius = 18.0
    var shadow = 0.7
    var aspect = AspectChoice.wide

    var showCursor = true
    var cursorScale = 1.6
    var smoothCursor = true
    var clickEffect = true

    var autoZoom = true
    var zoomLevel = 1.8

    /// Legacy single-recording trim; migrated into the first clip on load.
    var trimStart = 0.0
    var trimEnd = 0.0

    var exportResolution = ExportResolution.p1080

    /// Per audio lane ("microphone", "system-audio", "clip-audio"), 0…1. Missing means 1.
    var volumes: [String: Double] = [:]
    var muted: [String] = []

    /// 0 = off … 1 = strong, for the cursor and camera moves.
    var motionBlur = 0.5

    var showCamera = true
    var cameraShape = CameraShape.circle
    /// Bubble height as a share of the output height.
    var cameraSize = 0.26
    var cameraCorner = CameraCorner.bottomRight
    var mirrorCamera = true
    /// Free bubble position (centre, normalized to the output frame, top-left origin). Set by
    /// dragging the bubble on the preview; nil uses `cameraCorner`.
    var cameraX: Double?
    var cameraY: Double?
    /// Follow where the bubble was dragged while recording, when the recording has that path.
    var cameraFollowsRecording = true
    /// Keep the face centred in the bubble (from an on-device face track of the camera video).
    var centerFace = true
    var cameraBackground = CameraBackground.none

    /// Vertical/square output: fill the frame with the recording and follow the cursor, instead of
    /// fitting the whole screen (tiny) into it.
    var reframe = false

    /// Colours for the "custom" background (a brand gradient).
    var customGradient: [UInt32]?
    /// Logo shown on top of the video (brand kit).
    var watermark: Watermark?

    /// Speed used by "Speed up typing".
    var typingSpeed = 3.0

    /// The look of all subtitles, set in the subtitle editor. Nil until it's first set (older
    /// projects then take it from their first caption).
    var captionStyle: CaptionStyle?

    func volume(for kind: String) -> Float {
        muted.contains(kind) ? 0 : Float(volumes[kind] ?? 1)
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EditSettings()
        background = try c.decodeIfPresent(String.self, forKey: .background) ?? d.background
        backgroundBlur = try c.decodeIfPresent(Double.self, forKey: .backgroundBlur) ?? d.backgroundBlur
        padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? d.padding
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? d.cornerRadius
        shadow = try c.decodeIfPresent(Double.self, forKey: .shadow) ?? d.shadow
        aspect = (try? c.decodeIfPresent(AspectChoice.self, forKey: .aspect)) ?? d.aspect
        showCursor = try c.decodeIfPresent(Bool.self, forKey: .showCursor) ?? d.showCursor
        cursorScale = try c.decodeIfPresent(Double.self, forKey: .cursorScale) ?? d.cursorScale
        smoothCursor = try c.decodeIfPresent(Bool.self, forKey: .smoothCursor) ?? d.smoothCursor
        clickEffect = try c.decodeIfPresent(Bool.self, forKey: .clickEffect) ?? d.clickEffect
        autoZoom = try c.decodeIfPresent(Bool.self, forKey: .autoZoom) ?? d.autoZoom
        zoomLevel = try c.decodeIfPresent(Double.self, forKey: .zoomLevel) ?? d.zoomLevel
        trimStart = try c.decodeIfPresent(Double.self, forKey: .trimStart) ?? d.trimStart
        trimEnd = try c.decodeIfPresent(Double.self, forKey: .trimEnd) ?? d.trimEnd
        exportResolution = (try? c.decodeIfPresent(ExportResolution.self, forKey: .exportResolution)) ?? d.exportResolution
        volumes = try c.decodeIfPresent([String: Double].self, forKey: .volumes) ?? d.volumes
        muted = try c.decodeIfPresent([String].self, forKey: .muted) ?? d.muted
        motionBlur = try c.decodeIfPresent(Double.self, forKey: .motionBlur) ?? d.motionBlur
        showCamera = try c.decodeIfPresent(Bool.self, forKey: .showCamera) ?? d.showCamera
        cameraShape = (try? c.decodeIfPresent(CameraShape.self, forKey: .cameraShape)) ?? d.cameraShape
        cameraSize = try c.decodeIfPresent(Double.self, forKey: .cameraSize) ?? d.cameraSize
        cameraCorner = (try? c.decodeIfPresent(CameraCorner.self, forKey: .cameraCorner)) ?? d.cameraCorner
        mirrorCamera = try c.decodeIfPresent(Bool.self, forKey: .mirrorCamera) ?? d.mirrorCamera
        cameraX = try c.decodeIfPresent(Double.self, forKey: .cameraX)
        cameraY = try c.decodeIfPresent(Double.self, forKey: .cameraY)
        cameraFollowsRecording = try c.decodeIfPresent(Bool.self, forKey: .cameraFollowsRecording) ?? d.cameraFollowsRecording
        centerFace = try c.decodeIfPresent(Bool.self, forKey: .centerFace) ?? d.centerFace
        cameraBackground = (try? c.decodeIfPresent(CameraBackground.self, forKey: .cameraBackground)) ?? d.cameraBackground
        reframe = try c.decodeIfPresent(Bool.self, forKey: .reframe) ?? d.reframe
        customGradient = try c.decodeIfPresent([UInt32].self, forKey: .customGradient)
        watermark = try? c.decodeIfPresent(Watermark.self, forKey: .watermark)
        typingSpeed = try c.decodeIfPresent(Double.self, forKey: .typingSpeed) ?? d.typingSpeed
        captionStyle = try? c.decodeIfPresent(CaptionStyle.self, forKey: .captionStyle)
    }
}

/// One look for every subtitle. Generated captions get it, so regenerating keeps the style.
struct CaptionStyle: Codable, Equatable {
    var size = 0.042
    /// Vertical centre, normalized to the output frame, top-left origin.
    var y = 0.9
    var style = TextOverlay.Style.pill
    var color: UInt32 = 0xFFFFFF
    /// Nil = system bold.
    var fontName: String?
    /// Nil = automatic dark/light.
    var pillColor: UInt32?
    /// Nil = 88% of the frame.
    var wrapWidth: Double?

    init() {}

    init(_ text: TextOverlay) {
        size = text.size
        y = text.y
        style = text.style
        color = text.color
        fontName = text.fontName
        pillColor = text.pillColor
        wrapWidth = text.wrapWidth
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CaptionStyle()
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? d.size
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? d.y
        style = (try? c.decodeIfPresent(TextOverlay.Style.self, forKey: .style)) ?? d.style
        color = try c.decodeIfPresent(UInt32.self, forKey: .color) ?? d.color
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName)
        pillColor = try c.decodeIfPresent(UInt32.self, forKey: .pillColor)
        wrapWidth = try c.decodeIfPresent(Double.self, forKey: .wrapWidth)
    }

    /// Gives a subtitle this look. With `old`, only what differs from it is applied, so changing
    /// one property for all keeps per-line tweaks of the others.
    func apply(to text: inout TextOverlay, changedFrom old: CaptionStyle? = nil) {
        func changed<T: Equatable>(_ path: KeyPath<CaptionStyle, T>) -> Bool {
            old.map { $0[keyPath: path] != self[keyPath: path] } ?? true
        }
        if changed(\.size) { text.size = size }
        if changed(\.y) { text.y = y }
        if changed(\.style) { text.style = style }
        if changed(\.color) { text.color = color }
        if changed(\.fontName) { text.fontName = fontName }
        if changed(\.pillColor) { text.pillColor = pillColor }
        if changed(\.wrapWidth) { text.wrapWidth = wrapWidth }
    }
}

struct ZoomSegment: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var zoom: Double
    var enabled = true
    /// Generated from clicks (replaced on "Regenerate") vs. added by hand.
    var auto = true
    /// Fixed focus in normalized recording coordinates (0…1, top-left origin). Nil follows the cursor.
    var focusX: Double?
    var focusY: Double?

    var focus: CGPoint? {
        get { focusX.flatMap { x in focusY.map { CGPoint(x: x, y: $0) } } }
        set {
            focusX = newValue.map { Double($0.x) }
            focusY = newValue.map { Double($0.y) }
        }
    }
}

/// One piece of the edit: a span of a ScreenFrame recording or of a plain video file. Clips play
/// back to back; zooms live on the clip, in that clip's source time.
struct Clip: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case recording, video }

    var id = UUID()
    var kind: Kind
    /// Relative to the project folder: a folder with recording.json ("." is the project's own
    /// recording) or a video file.
    var source: String
    var name: String
    var start: Double
    var end: Double
    var zooms: [ZoomSegment] = []
    /// Video files only: pixel size and full length, probed when the clip is added.
    var width: Double?
    var height: Double?
    var sourceDuration: Double?
    // Optional so project files from before these existed still decode; use the accessors below.
    var playbackSpeed: Double?
    var laneVolumes: [String: Double]?
    var cameraLayout: CameraLayout?
    /// Transition into the next clip.
    var transition: ClipTransition?
    /// A brand intro/outro card: drawn full-bleed, without frame, cursor, camera or logo.
    var isCard: Bool?

    enum CameraLayout: String, Codable, CaseIterable, Identifiable {
        case overlay, fullscreen, hidden
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    /// Source span (end - start), before speed.
    var duration: Double { max(0, end - start) }

    var speed: Double {
        get { playbackSpeed ?? 1 }
        set { playbackSpeed = abs(newValue - 1) < 0.001 ? nil : newValue }
    }

    var camera: CameraLayout {
        get { cameraLayout ?? .overlay }
        set { cameraLayout = newValue == .overlay ? nil : newValue }
    }

    func volume(for kind: String) -> Double { laneVolumes?[kind] ?? 1 }

    mutating func setVolume(_ value: Double, for kind: String) {
        var volumes = laneVolumes ?? [:]
        volumes[kind] = abs(value - 1) < 0.001 ? nil : value
        laneVolumes = volumes.isEmpty ? nil : volumes
    }
}

struct ClipTransition: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case crossfade, fade, slide
        var id: String { rawValue }
        var label: String {
            switch self {
            case .crossfade: return "Crossfade"
            case .fade: return "Fade through black"
            case .slide: return "Slide"
            }
        }
    }

    var kind: Kind
    var duration = 0.6
}

struct TextOverlay: Codable, Identifiable, Equatable {
    enum Style: String, Codable, CaseIterable, Identifiable {
        case pill, shadow, plain
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    var id = UUID()
    var text = "Your title"
    /// Timeline time.
    var start: Double
    var end: Double
    /// Centre, normalized to the output frame, top-left origin.
    var x = 0.5
    var y = 0.85
    /// Font size as a share of the output height.
    var size = 0.055
    var color: UInt32 = 0xFFFFFF
    var style = Style.pill
    /// Generated subtitle (shown in the Captions lane) rather than a title.
    var isCaption: Bool?
    /// Brand font (PostScript or family name); nil = system bold.
    var fontName: String?
    /// Pill background colour; nil = automatic dark/light.
    var pillColor: UInt32?
    /// Added by a brand kit (lower third), so re-applying a kit replaces it.
    var brand: Bool?
    /// Wrap width as a share of the frame (default 88%).
    var wrapWidth: Double?

    var caption: Bool { isCaption ?? false }
}

/// A camera keyframe on the Camera lane: from `t` on, the bubble sits at (x, y) in the given
/// layout, gliding there over half a second.
struct CameraKey: Codable, Identifiable, Equatable {
    var id = UUID()
    /// Timeline time.
    var t: Double
    /// Bubble centre, normalized to the output frame, top-left origin.
    var x: Double
    var y: Double
    var layout: Clip.CameraLayout?
    /// Generated by "Auto layout" (replaced when it runs again).
    var auto: Bool?
}

/// A blurred area of a clip's picture: found by the privacy scan or added by hand.
struct BlurRegion: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case email, phone, secret, name, face, manual
        var id: String { rawValue }
        var label: String {
            switch self {
            case .email: return "Emails"
            case .phone: return "Phone numbers"
            case .secret: return "Keys & tokens"
            case .name: return "Names"
            case .face: return "Faces"
            case .manual: return "Manual"
            }
        }
    }

    var id = UUID()
    /// The clip source (media) it belongs to; times are that media's source time.
    var source: String
    var kind: Kind
    var start: Double
    var end: Double
    /// Normalized to the source picture, top-left origin.
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var enabled = true
    /// What was detected, for the list in the inspector.
    var label: String?
}

/// project.json: the editable half of a project.
struct ProjectDoc: Codable {
    var name: String
    var createdAt: Date
    var settings: EditSettings
    var clips: [Clip]
    var texts: [TextOverlay]
    var cameraKeys: [CameraKey] = []
    var blurs: [BlurRegion] = []
    /// Zooms from single-recording projects, before clips existed. Only read for migration.
    var legacyZooms: [ZoomSegment] = []

    init(name: String, createdAt: Date, settings: EditSettings, clips: [Clip], texts: [TextOverlay] = []) {
        self.name = name
        self.createdAt = createdAt
        self.settings = settings
        self.clips = clips
        self.texts = texts
    }

    private enum CodingKeys: String, CodingKey { case name, createdAt, settings, clips, texts, zooms, cameraKeys, blurs }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        settings = try c.decodeIfPresent(EditSettings.self, forKey: .settings) ?? EditSettings()
        clips = try c.decodeIfPresent([Clip].self, forKey: .clips) ?? []
        texts = try c.decodeIfPresent([TextOverlay].self, forKey: .texts) ?? []
        legacyZooms = try c.decodeIfPresent([ZoomSegment].self, forKey: .zooms) ?? []
        cameraKeys = try c.decodeIfPresent([CameraKey].self, forKey: .cameraKeys) ?? []
        blurs = try c.decodeIfPresent([BlurRegion].self, forKey: .blurs) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(settings, forKey: .settings)
        try c.encode(clips, forKey: .clips)
        try c.encode(texts, forKey: .texts)
        try c.encode(cameraKeys, forKey: .cameraKeys)
        try c.encode(blurs, forKey: .blurs)
    }
}
