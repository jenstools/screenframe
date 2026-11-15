import Foundation

/// The look of a short: captions, hook title, progress bar, split, logo and frame. A preset that is
/// written into a short's settings and texts (so everything stays editable there), and read back
/// from them for the style editor.
struct ShortStyle: Codable, Equatable, Identifiable {
    enum CaptionPosition: String, Codable, CaseIterable, Identifiable {
        /// On the seam in the split layout, low otherwise.
        case auto, top, middle, bottom
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    var id = UUID()
    var name: String

    // Captions
    var captionStyle = TextOverlay.Style.pill
    var captionFont: String?
    var captionColor: UInt32 = 0xFFFFFF
    /// Pill background or outline colour; nil = automatic.
    var captionBackground: UInt32?
    var captionSize = 0.032
    var captionUppercase = false
    var captionPosition = CaptionPosition.auto

    // Hook title (first seconds)
    var hookEnabled = true
    var hookStyle = TextOverlay.Style.pill
    var hookFont: String?
    var hookColor: UInt32 = 0xFFFFFF
    var hookBackground: UInt32?
    var hookSize = 0.038
    var hookUppercase = false
    var hookDuration = 3.5

    // Progress bar
    var progressEnabled = false
    var progressColors: [UInt32] = [0xFFFFFF]
    var progressAtTop = false

    // Split layout
    var splitRatio = 0.58
    var dividerEnabled = false
    var dividerColor: UInt32 = 0xFFFFFF

    // Logo and frame
    var logoEnabled = true
    /// Nil keeps the logo the video already has.
    var logoPath: String?
    var logoCorner = CameraCorner.topRight
    /// Share of the frame height (a 9:16 frame is tall, so smaller than in 16:9).
    var logoSize = 0.034
    /// Background preset id, or "custom" with `gradient`.
    var background: String?
    var gradient: [UInt32]?
    /// Screen inset in the frame; 0 = full bleed.
    var padding = 0.0

    /// Where captions sit (top-left origin) for a layout and split ratio.
    func captionY(layout: ShortLayout) -> Double {
        switch captionPosition {
        case .auto: return layout == .split ? splitRatio : 0.74
        case .top: return 0.2
        case .middle: return 0.5
        case .bottom: return 0.8
        }
    }

    /// Writes the style into a short. `hookText` is used when the short has no hook yet.
    func apply(to settings: inout EditSettings, texts: inout [TextOverlay], layout: ShortLayout,
               duration: Double, hookText: String?) {
        // Captions
        var caption = settings.captionStyle ?? CaptionStyle()
        caption.style = captionStyle
        caption.fontName = captionFont
        caption.color = captionColor
        caption.pillColor = captionBackground
        caption.size = captionSize
        caption.uppercase = captionUppercase ? true : nil
        caption.y = captionY(layout: layout)
        caption.wrapWidth = 0.84
        settings.captionStyle = caption
        for i in texts.indices where texts[i].caption { caption.apply(to: &texts[i]) }

        // Logo
        if logoEnabled, let path = logoPath ?? settings.watermark?.path {
            settings.watermark = Watermark(path: path, corner: logoCorner, size: logoSize, opacity: settings.watermark?.opacity ?? 0.9)
        } else {
            settings.watermark = nil
        }
        let logoOnTop = settings.watermark.map { $0.corner == .topLeft || $0.corner == .topRight } ?? false

        // Hook
        let hookIndex = texts.firstIndex(where: \.isHook) ?? texts.firstIndex { !$0.caption && $0.start < 0.5 && $0.brand != true }
        if hookEnabled {
            var hook = hookIndex.map { texts[$0] }
                ?? TextOverlay(text: hookText ?? "", start: 0, end: hookDuration, x: 0.5, y: 0.09)
            hook.hook = true
            hook.style = hookStyle
            hook.fontName = hookFont
            hook.color = hookColor
            hook.pillColor = hookBackground
            hook.size = hookSize
            hook.uppercase = hookUppercase ? true : nil
            hook.end = min(duration, hook.start + hookDuration)
            hook.y = logoOnTop ? 0.13 : 0.09
            hook.wrapWidth = 0.86
            if let hookIndex { texts[hookIndex] = hook } else if !hook.text.isEmpty { texts.append(hook) }
        } else if let hookIndex {
            texts.remove(at: hookIndex)
        }

        // Progress, split, frame
        settings.progressBar = progressEnabled ? ProgressBar(colors: progressColors, atTop: progressAtTop) : nil
        settings.splitRatio = splitRatio
        settings.splitDivider = dividerEnabled ? SplitDivider(color: dividerColor) : nil
        if let background {
            settings.background = background
            settings.customGradient = background == "custom" ? gradient : settings.customGradient
        }
        settings.padding = padding
    }

    /// The style a short currently has (for the editor), named after `name`.
    static func read(settings: EditSettings, texts: [TextOverlay], name: String = "Current") -> ShortStyle {
        var style = ShortStyle(name: name)
        let caption = settings.captionStyle ?? texts.first(where: \.caption).map(CaptionStyle.init) ?? CaptionStyle()
        style.captionStyle = caption.style
        style.captionFont = caption.fontName
        style.captionColor = caption.color
        style.captionBackground = caption.pillColor
        style.captionSize = caption.size
        style.captionUppercase = caption.uppercase ?? false
        style.splitRatio = settings.splitRatio ?? 0.58
        let auto = abs(caption.y - style.splitRatio) < 0.01 || abs(caption.y - 0.74) < 0.01
        style.captionPosition = auto ? .auto : caption.y < 0.35 ? .top : caption.y < 0.65 ? .middle : .bottom

        if let hook = texts.first(where: \.isHook) ?? texts.first(where: { !$0.caption && $0.start < 0.5 && $0.brand != true }) {
            style.hookEnabled = true
            style.hookStyle = hook.style
            style.hookFont = hook.fontName
            style.hookColor = hook.color
            style.hookBackground = hook.pillColor
            style.hookSize = hook.size
            style.hookUppercase = hook.uppercase ?? false
            style.hookDuration = max(1, hook.end - hook.start)
        } else {
            style.hookEnabled = false
        }

        style.progressEnabled = settings.progressBar != nil
        style.progressColors = settings.progressBar?.colors ?? [0xFFFFFF]
        style.progressAtTop = settings.progressBar?.atTop ?? false
        style.dividerEnabled = settings.splitDivider != nil
        style.dividerColor = settings.splitDivider?.color ?? 0xFFFFFF
        style.logoEnabled = settings.watermark != nil
        style.logoPath = settings.watermark?.path
        style.logoCorner = settings.watermark?.corner ?? .topRight
        style.logoSize = settings.watermark?.size ?? 0.034
        style.background = settings.background
        style.gradient = settings.customGradient
        style.padding = settings.padding
        return style
    }
}

/// Built-in styles, one per brand kit, and the user's saved ones (Application Support/ScreenFrame/shortstyles.json).
enum ShortStyleStore {
    private static var file: URL { BrandKitStore.folder.appendingPathComponent("shortstyles.json") }

    static func saved() -> [ShortStyle] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([ShortStyle].self, from: data)) ?? []
    }

    static func save(_ styles: [ShortStyle]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(styles).write(to: file, options: .atomic)
    }

    // Stable ids, so "the style for new shorts" survives restarts.
    private static func fixedID(_ n: Int) -> UUID { UUID(uuidString: String(format: "5F0A7E00-0000-4000-8000-%012d", n))! }

    static let builtIn: [ShortStyle] = {
        var clean = ShortStyle(id: fixedID(1), name: "Clean")
        clean.captionBackground = 0x1C1C1E

        var bold = ShortStyle(id: fixedID(2), name: "Bold")
        bold.captionStyle = .outline
        bold.captionSize = 0.04
        bold.captionUppercase = true
        bold.captionColor = 0xFFFFFF
        bold.hookStyle = .pill
        bold.hookColor = 0x1C1C1E
        bold.hookBackground = 0xFFD60A
        bold.hookUppercase = true
        bold.hookSize = 0.042
        bold.progressEnabled = true
        bold.progressColors = [0xFFD60A]
        bold.dividerEnabled = true
        bold.dividerColor = 0xFFD60A

        var minimal = ShortStyle(id: fixedID(3), name: "Minimal")
        minimal.captionStyle = .shadow
        minimal.captionSize = 0.03
        minimal.hookStyle = .shadow
        minimal.hookSize = 0.036
        minimal.logoEnabled = false

        var karaoke = ShortStyle(id: fixedID(4), name: "Pop")
        karaoke.captionStyle = .pill
        karaoke.captionColor = 0x1C1C1E
        karaoke.captionBackground = 0xFFFFFF
        karaoke.captionSize = 0.036
        karaoke.hookColor = 0xFFFFFF
        karaoke.hookBackground = 0xFF375F
        karaoke.progressEnabled = true
        karaoke.progressColors = [0xFF375F, 0xFF9F0A]
        return [clean, bold, minimal, karaoke]
    }()

    /// The kit's CI: brand font everywhere, accent-coloured caption pills, hook in the first gradient
    /// colour, gradient progress bar and background, the kit's logo.
    static func from(_ kit: BrandKit, index: Int) -> ShortStyle {
        var style = ShortStyle(id: fixedID(100 + index), name: kit.name)
        let font = kit.fontPostScriptName
        let first = kit.gradient.first ?? kit.accentColor
        style.captionFont = font
        style.captionColor = kit.textColor
        style.captionBackground = kit.accentColor
        style.hookFont = font
        style.hookColor = kit.textColor
        style.hookBackground = first
        style.progressEnabled = true
        style.progressColors = kit.gradient.isEmpty ? [kit.accentColor] : kit.gradient
        style.dividerEnabled = true
        style.dividerColor = first
        style.logoEnabled = kit.logoPath != nil
        style.logoPath = kit.logoPath
        style.logoCorner = kit.logoCorner
        style.logoSize = kit.logoSize * 9 / 16
        style.background = "custom"
        style.gradient = kit.gradient
        return style
    }

    static func brand(_ kits: [BrandKit]) -> [ShortStyle] {
        kits.enumerated().map { from($1, index: $0) }
    }

    static func all(kits: [BrandKit]) -> [ShortStyle] { builtIn + brand(kits) + saved() }

    static func find(_ id: String?, kits: [BrandKit]) -> ShortStyle? {
        guard let id else { return nil }
        return all(kits: kits).first { $0.id.uuidString == id }
    }
}
