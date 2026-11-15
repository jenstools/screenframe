import AppKit
import SwiftUI

// MARK: - Style section in a short

/// The Style section of a short's Social tab: presets on top, every detail below.
struct ShortStyleSection: View {
    @ObservedObject var model: EditorModel
    @State private var open: Set<String> = ["captions"]
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        let style = model.shortStyle
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Style") {
                Menu {
                    Button("Save as Preset…") { newName = ""; naming = true }
                    Button("Apply to All Shorts of This Video") { model.applyStyleToSiblings(style) }
                    let saved = ShortStyleStore.saved()
                    if !saved.isEmpty {
                        Divider()
                        Menu("Delete Preset") {
                            ForEach(saved) { preset in Button(preset.name) { model.deleteShortStyle(preset) } }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Save or share this style")
            }
            StyleGrid(styles: model.shortStyles, selectedName: model.shortInfo?.styleName) { model.applyShortStyle($0) }

            VStack(spacing: 6) {
                group("captions", "Captions", symbol: "captions.bubble") { CaptionControls(model: model, style: style) }
                group("hook", "Hook title", symbol: "textformat.size", on: style.hookEnabled,
                      toggle: { v in model.editShortStyle { $0.hookEnabled = v } }) { HookControls(model: model, style: style) }
                group("progress", "Progress bar", symbol: "minus", on: style.progressEnabled,
                      toggle: { v in model.editShortStyle { $0.progressEnabled = v } }) { ProgressControls(model: model, style: style) }
                if model.shortLayout == .split {
                    group("split", "Split", symbol: "rectangle.split.1x2") { SplitControls(model: model, style: style) }
                }
                group("frame", "Logo & background", symbol: "seal") { FrameControls(model: model, style: style) }
            }
        }
        .alert("Save Style", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Save") { model.saveShortStyle(named: newName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved styles show up for every short and for new ones.")
        }
    }

    /// A collapsible group with an optional on/off switch in its header.
    private func group<Content: View>(_ id: String, _ title: String, symbol: String, on: Bool? = nil,
                                      toggle: ((Bool) -> Void)? = nil, @ViewBuilder content: () -> Content) -> some View {
        let expanded = open.contains(id) && on != false
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { if open.contains(id) { open.remove(id) } else { open.insert(id) } }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: symbol).frame(width: 16).foregroundStyle(.secondary)
                        Text(title).font(.callout.weight(.medium))
                        Spacer(minLength: 0)
                        if on != false {
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if let on, let toggle {
                    Toggle("", isOn: Binding(get: { on }, set: { v in toggle(v); if v { open.insert(id) } }))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                }
            }
            if expanded { content() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
    }
}

// MARK: - Groups

private struct CaptionControls: View {
    @ObservedObject var model: EditorModel
    let style: ShortStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextStylePicker(selection: Binding(get: { style.captionStyle }, set: { v in model.editShortStyle { $0.captionStyle = v } }))
            Row("Font") {
                FontMenu(model: model, selection: Binding(get: { style.captionFont }, set: { v in model.editShortStyle { $0.captionFont = v } }))
            }
            Row("Text") {
                ColorRow(model: model, selection: Binding(get: { style.captionColor }, set: { v in model.editShortStyle { $0.captionColor = v ?? 0xFFFFFF } }))
            }
            if style.captionStyle == .pill || style.captionStyle == .outline {
                Row(style.captionStyle == .outline ? "Outline" : "Box") {
                    ColorRow(model: model, allowsAuto: true,
                             selection: Binding(get: { style.captionBackground }, set: { v in model.editShortStyle { $0.captionBackground = v } }))
                }
            }
            Row("Size") {
                Slider(value: Binding(get: { style.captionSize }, set: { v in model.editShortStyle { $0.captionSize = v } }), in: 0.022...0.055)
            }
            Row("Position") {
                Picker("", selection: Binding(get: { style.captionPosition }, set: { v in model.editShortStyle { $0.captionPosition = v } })) {
                    ForEach(ShortStyle.CaptionPosition.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            Toggle("UPPERCASE", isOn: Binding(get: { style.captionUppercase }, set: { v in model.editShortStyle { $0.captionUppercase = v } }))
                .toggleStyle(.checkbox)
        }
        .controlSize(.small)
    }
}

private struct HookControls: View {
    @ObservedObject var model: EditorModel
    let style: ShortStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Hook", text: Binding(get: { model.hookText }, set: { model.setHookText($0) }), axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.plain)
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
            TextStylePicker(selection: Binding(get: { style.hookStyle }, set: { v in model.editShortStyle { $0.hookStyle = v } }))
            Row("Font") {
                FontMenu(model: model, selection: Binding(get: { style.hookFont }, set: { v in model.editShortStyle { $0.hookFont = v } }))
            }
            Row("Text") {
                ColorRow(model: model, selection: Binding(get: { style.hookColor }, set: { v in model.editShortStyle { $0.hookColor = v ?? 0xFFFFFF } }))
            }
            if style.hookStyle == .pill || style.hookStyle == .outline {
                Row(style.hookStyle == .outline ? "Outline" : "Box") {
                    ColorRow(model: model, allowsAuto: true,
                             selection: Binding(get: { style.hookBackground }, set: { v in model.editShortStyle { $0.hookBackground = v } }))
                }
            }
            Row("Size") {
                Slider(value: Binding(get: { style.hookSize }, set: { v in model.editShortStyle { $0.hookSize = v } }), in: 0.028...0.06)
            }
            Row("Shows") {
                Slider(value: Binding(get: { style.hookDuration }, set: { v in model.editShortStyle { $0.hookDuration = (v * 2).rounded() / 2 } }),
                       in: 1.5...8)
                Text(String(format: "%.1f s", style.hookDuration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            Toggle("UPPERCASE", isOn: Binding(get: { style.hookUppercase }, set: { v in model.editShortStyle { $0.hookUppercase = v } }))
                .toggleStyle(.checkbox)
        }
        .controlSize(.small)
    }
}

private struct ProgressControls: View {
    @ObservedObject var model: EditorModel
    let style: ShortStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Row("Colour") {
                GradientRow(model: model, selection: Binding(get: { style.progressColors }, set: { v in model.editShortStyle { $0.progressColors = v } }))
            }
            Row("Where") {
                Picker("", selection: Binding(get: { style.progressAtTop }, set: { v in model.editShortStyle { $0.progressAtTop = v } })) {
                    Text("Bottom").tag(false)
                    Text("Top").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
        }
        .controlSize(.small)
    }
}

private struct SplitControls: View {
    @ObservedObject var model: EditorModel
    let style: ShortStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Row("Camera") {
                Slider(value: Binding(get: { 1 - style.splitRatio }, set: { v in model.editShortStyle { $0.splitRatio = 1 - (v * 100).rounded() / 100 } }),
                       in: 0.3...0.55)
                Text("\(Int(((1 - style.splitRatio) * 100).rounded()))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            Toggle("Line between screen and camera",
                   isOn: Binding(get: { style.dividerEnabled }, set: { v in model.editShortStyle { $0.dividerEnabled = v } }))
                .toggleStyle(.checkbox)
            if style.dividerEnabled {
                Row("Line") {
                    ColorRow(model: model, selection: Binding(get: { style.dividerColor }, set: { v in model.editShortStyle { $0.dividerColor = v ?? 0xFFFFFF } }))
                }
            }
        }
        .controlSize(.small)
    }
}

private struct FrameControls: View {
    @ObservedObject var model: EditorModel
    let style: ShortStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Show logo", isOn: Binding(get: { style.logoEnabled }, set: { v in
                model.editShortStyle { $0.logoEnabled = v; if v, $0.logoPath == nil { $0.logoPath = model.brandKits.first?.logoPath } }
            }))
            .toggleStyle(.checkbox)
            .disabled(style.logoPath == nil && model.brandKits.allSatisfy { $0.logoPath == nil })
            if style.logoEnabled {
                Row("Corner") {
                    HStack(spacing: 4) {
                        ForEach([CameraCorner.topLeft, .topRight, .bottomLeft, .bottomRight], id: \.self) { corner in
                            Button { model.editShortStyle { $0.logoCorner = corner } } label: {
                                CornerGlyph(corner: corner, selected: style.logoCorner == corner)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Row("Size") {
                    Slider(value: Binding(get: { style.logoSize }, set: { v in model.editShortStyle { $0.logoSize = v } }), in: 0.018...0.07)
                }
            }
            Row("Background") {
                BackgroundRow(model: model, style: style)
            }
            Row("Frame") {
                Slider(value: Binding(get: { style.padding }, set: { v in model.editShortStyle { $0.padding = v } }), in: 0...0.12)
                Text(style.padding < 0.005 ? "Full" : "\(Int((style.padding * 100).rounded()))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
            }
        }
        .controlSize(.small)
    }
}

// MARK: - Presets

/// Tiles with a drawn preview of each style; tap applies.
struct StyleGrid: View {
    let styles: [ShortStyle]
    let selectedName: String?
    let pick: (ShortStyle) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            ForEach(styles) { style in
                let selected = style.name == selectedName
                Button { pick(style) } label: {
                    VStack(spacing: 4) {
                        StylePreview(style: style)
                            .frame(width: 44)
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1))
                        Text(style.name).font(.caption2.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Color.accentColor : .secondary)
                            .lineLimit(1)
                            .frame(width: 52)
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(style.name)
            }
          }
          .padding(.horizontal, 1)
        }
    }
}

/// A tiny 9:16 sketch of a style: background, hook, split, caption, progress bar.
struct StylePreview: View {
    let style: ShortStyle

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .top) {
                background
                VStack(spacing: 0) {
                    Rectangle().fill(Color(white: 0.92)).frame(height: h * style.splitRatio)
                        .overlay(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(0..<3) { i in Capsule().fill(Color(white: 0.75)).frame(width: w * [0.5, 0.7, 0.4][i], height: 2) }
                            }
                            .padding(.top, h * 0.24).padding(.leading, 5)
                        }
                    Rectangle().fill(Color(white: 0.32))
                        .overlay(Image(systemName: "person.fill").font(.system(size: h * 0.16)).foregroundStyle(Color(white: 0.55)))
                }
                .padding(style.padding * w * 2)
                if style.dividerEnabled {
                    Rectangle().fill(Color(hex: style.dividerColor)).frame(height: 1.5).offset(y: h * style.splitRatio - 0.75)
                }
                if style.hookEnabled {
                    label(width: w * 0.62, height: h * 0.07, kind: style.hookStyle, fill: style.hookColor, back: style.hookBackground)
                        .offset(y: h * 0.09)
                }
                label(width: w * 0.7, height: h * 0.06, kind: style.captionStyle, fill: style.captionColor, back: style.captionBackground)
                    .offset(y: h * style.captionY(layout: .split) - h * 0.03)
                if style.progressEnabled {
                    progress.frame(width: w, height: 2.5)
                        .frame(maxHeight: .infinity, alignment: style.progressAtTop ? .top : .bottom)
                }
            }
        }
        .aspectRatio(9 / 16, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder private var background: some View {
        if style.background == "custom", let g = style.gradient, !g.isEmpty {
            LinearGradient(colors: g.map { Color(hex: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing)
        } else {
            Color(white: 0.2)
        }
    }

    private var progress: some View {
        let colors = style.progressColors.isEmpty ? [UInt32(0xFFFFFF)] : style.progressColors
        return HStack(spacing: 0) {
            LinearGradient(colors: colors.map { Color(hex: $0) }, startPoint: .leading, endPoint: .trailing)
                .frame(maxWidth: .infinity)
            Color.white.opacity(0.25).frame(maxWidth: .infinity)
        }
    }

    /// A pill / outlined / shadowed bar standing in for text.
    @ViewBuilder private func label(width: CGFloat, height: CGFloat, kind: TextOverlay.Style, fill: UInt32, back: UInt32?) -> some View {
        switch kind {
        case .pill:
            Capsule().fill(Color(hex: back ?? 0x1C1C1E).opacity(0.9))
                .frame(width: width, height: height)
                .overlay(Capsule().fill(Color(hex: fill)).frame(width: width * 0.7, height: max(1.5, height * 0.3)))
        case .outline:
            Capsule().fill(Color(hex: fill)).frame(width: width * 0.8, height: max(2, height * 0.45))
                .overlay(Capsule().strokeBorder(Color(hex: back ?? 0x000000), lineWidth: 1.2))
        case .shadow, .plain:
            Capsule().fill(Color(hex: fill)).frame(width: width * 0.8, height: max(2, height * 0.4))
                .shadow(color: .black.opacity(kind == .shadow ? 0.8 : 0), radius: 1.5)
        }
    }
}

// MARK: - Controls

/// A label column and a control.
private struct Row<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
            content
        }
    }
}

private struct TextStylePicker: View {
    @Binding var selection: TextOverlay.Style

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(TextOverlay.Style.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

/// Brand fonts first, then a few bold system faces.
private struct FontMenu: View {
    @ObservedObject var model: EditorModel
    @Binding var selection: String?

    var body: some View {
        Picker("", selection: $selection) {
            Text("System Bold").tag(String?.none)
            Divider()
            ForEach(fonts, id: \.name) { Text($0.label).tag(Optional($0.name)) }
        }
        .labelsHidden()
    }

    private var fonts: [(name: String, label: String)] {
        var names = model.brandKits.map(\.fontPostScriptName)
        names += ["AvenirNext-Heavy", "AvenirNext-Bold", "HelveticaNeue-Bold", "Futura-Bold", "Impact", "GillSans-Bold",
                  "Georgia-Bold", "Menlo-Bold", "MarkerFelt-Wide"]
        if let selection { names.insert(selection, at: 0) }
        var seen = Set<String>()
        return names.compactMap { name in
            guard seen.insert(name).inserted, let font = NSFont(name: name, size: 12) else { return nil }
            return (name, font.displayName ?? name)
        }
    }
}

/// Colours of the brand kits (the CI) and a few basics, plus a picker for any colour.
private struct ColorRow: View {
    @ObservedObject var model: EditorModel
    var allowsAuto = false
    @Binding var selection: UInt32?

    var body: some View {
        HStack(spacing: 4) {
            if allowsAuto {
                Button { selection = nil } label: {
                    Text("Auto").font(.system(size: 9, weight: .medium))
                        .frame(width: 30, height: 18)
                        .overlay(Capsule().strokeBorder(selection == nil ? Color.accentColor : Color.primary.opacity(0.25),
                                                        lineWidth: selection == nil ? 2 : 1))
                }
                .buttonStyle(.plain)
                .help("Dark or light, to suit the text")
            }
            ForEach(palette.prefix(allowsAuto ? 5 : 6), id: \.self) { color in
                Swatch(color: color, selected: selection == color) { selection = color }
            }
            CustomColorButton(color: selection ?? 0xFFFFFF, isCustom: selection.map { !palette.prefix(allowsAuto ? 5 : 6).contains($0) } ?? false) {
                selection = $0
            }
        }
    }

    private var palette: [UInt32] { BrandPalette.colors(model.brandKits) }
}

/// One colour or a brand gradient for the progress bar.
private struct GradientRow: View {
    @ObservedObject var model: EditorModel
    @Binding var selection: [UInt32]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(model.brandKits.enumerated()), id: \.offset) { _, kit in
                if kit.gradient.count > 1 {
                    Button { selection = kit.gradient } label: {
                        Circle().fill(LinearGradient(colors: kit.gradient.map { Color(hex: $0) }, startPoint: .leading, endPoint: .trailing))
                            .frame(width: 16, height: 16)
                            .overlay(Circle().strokeBorder(selection == kit.gradient ? Color.accentColor : Color.primary.opacity(0.25),
                                                           lineWidth: selection == kit.gradient ? 2.5 : 1))
                    }
                    .buttonStyle(.plain)
                    .help("\(kit.name) gradient")
                }
            }
            ForEach(BrandPalette.colors(model.brandKits).prefix(4), id: \.self) { color in
                Swatch(color: color, selected: selection == [color]) { selection = [color] }
            }
            CustomColorButton(color: selection.first ?? 0xFFFFFF, isCustom: false) { selection = [$0] }
        }
    }
}

/// Brand gradients, then the standard backgrounds.
private struct BackgroundRow: View {
    @ObservedObject var model: EditorModel
    let style: ShortStyle

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(model.brandKits.enumerated()), id: \.offset) { _, kit in
                tile(LinearGradient(colors: kit.gradient.map { Color(hex: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing),
                     selected: style.background == "custom" && style.gradient == kit.gradient, help: "\(kit.name) gradient") {
                    model.editShortStyle { $0.background = "custom"; $0.gradient = kit.gradient }
                }
            }
            ForEach(["graphite", "midnight", "aurora", "sunset", "paper"], id: \.self) { id in
                let preset = BackgroundPreset.named(id)
                tile(fill(preset), selected: style.background == id, help: preset.name) {
                    model.editShortStyle { $0.background = id }
                }
            }
        }
    }

    private func fill(_ preset: BackgroundPreset) -> AnyShapeStyle {
        switch preset.kind {
        case .gradient(let colors):
            return AnyShapeStyle(LinearGradient(colors: colors.map { Color(hex: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing))
        case .solid(let color): return AnyShapeStyle(Color(hex: color))
        case .wallpaper: return AnyShapeStyle(Color.gray)
        }
    }

    private func tile<S: ShapeStyle>(_ fill: S, selected: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 4).fill(fill)
                .frame(width: 18, height: 18)
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.2), lineWidth: selected ? 2.5 : 1))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A rainbow swatch that opens the system colour panel; picked colours come back live.
private struct CustomColorButton: View {
    let color: UInt32
    let isCustom: Bool
    let pick: (UInt32) -> Void

    var body: some View {
        Button { ColorPanelBridge.shared.open(with: color, pick) } label: {
            ZStack {
                Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                if isCustom { Circle().fill(Color(hex: color)).padding(3.5) }
            }
            .frame(width: 16, height: 16)
            .overlay(Circle().strokeBorder(isCustom ? Color.accentColor : Color.primary.opacity(0.25), lineWidth: isCustom ? 2.5 : 1))
        }
        .buttonStyle(.plain)
        .help("Any colour…")
    }
}

/// Routes NSColorPanel changes to whichever swatch opened it last.
@MainActor
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var handler: ((UInt32) -> Void)?

    func open(with color: UInt32, _ handler: @escaping (UInt32) -> Void) {
        self.handler = nil
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = NSColor(Color(hex: color))
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        self.handler = handler
        panel.orderFront(nil)
    }

    @objc private func changed(_ panel: NSColorPanel) {
        handler?(Color(nsColor: panel.color).hexValue)
    }
}

private struct Swatch: View {
    let color: UInt32
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle().fill(Color(hex: color)).frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.25), lineWidth: selected ? 2.5 : 1))
        }
        .buttonStyle(.plain)
    }
}

private struct CornerGlyph: View {
    let corner: CameraCorner
    let selected: Bool

    var body: some View {
        let top = corner == .topLeft || corner == .topRight
        let left = corner == .topLeft || corner == .bottomLeft
        RoundedRectangle(cornerRadius: 3)
            .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: selected ? 1.5 : 1)
            .frame(width: 16, height: 24)
            .overlay(alignment: top ? (left ? .topLeading : .topTrailing) : (left ? .bottomLeading : .bottomTrailing)) {
                RoundedRectangle(cornerRadius: 1).fill(selected ? Color.accentColor : Color.secondary).frame(width: 6, height: 4).padding(3)
            }
    }
}

/// Every colour of the brand kits (gradient, accent, text), then neutral and signal colours.
enum BrandPalette {
    static func colors(_ kits: [BrandKit]) -> [UInt32] {
        var list: [UInt32] = []
        for kit in kits { list += kit.gradient + [kit.accentColor, kit.textColor] }
        list += [0xFFFFFF, 0x1C1C1E, 0xFFD60A, 0xFF375F, 0x0A84FF]
        var seen = Set<UInt32>()
        return list.filter { seen.insert($0).inserted }
    }
}

extension Color {
    /// sRGB as 0xRRGGBB.
    var hexValue: UInt32 {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .white
        func byte(_ v: CGFloat) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
        return byte(c.redComponent) << 16 | byte(c.greenComponent) << 8 | byte(c.blueComponent)
    }
}
