import AppKit
import SwiftUI

/// Saved choices for making shorts (shared by the Social tab and the one-click card).
enum ShortsDefaults {
    static let layoutKey = "shortsLayout"
    static let lengthKey = "shortsLength"
    /// 0 = automatic.
    static let countKey = "shortsCount"

    static var layout: ShortLayout { ShortLayout(rawValue: UserDefaults.standard.string(forKey: layoutKey) ?? "") ?? .split }
    static var length: ShortsPlanner.Length {
        ShortsPlanner.Length(rawValue: UserDefaults.standard.string(forKey: lengthKey) ?? "") ?? .standard
    }
    static var count: Int? {
        let n = UserDefaults.standard.integer(forKey: countKey)
        return n > 0 ? n : nil
    }
    static let styleKey = "shortsStyle"
    /// The style for new shorts: the one picked last, else the first brand kit's (CI), else Clean.
    static func style(kits: [BrandKit]) -> ShortStyle {
        ShortStyleStore.find(UserDefaults.standard.string(forKey: styleKey), kits: kits)
            ?? ShortStyleStore.brand(kits).first ?? ShortStyleStore.builtIn[0]
    }
}

extension EditorModel {
    /// "Make Shorts" with the options last chosen in the Social tab.
    func makeShortsFromDefaults() {
        makeShorts(count: ShortsDefaults.count, length: ShortsDefaults.length, layout: ShortsDefaults.layout)
    }
}

/// The inspector's Social tab. In a video: make shorts and manage them. In a short: its post text,
/// layout and export.
struct SocialTab: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        if let info = model.shortInfo {
            ShortDetail(model: model, info: info)
        } else {
            ShortsOverview(model: model)
        }
    }
}

// MARK: - Original video

private struct ShortsOverview: View {
    @ObservedObject var model: EditorModel
    @AppStorage(ShortsDefaults.layoutKey) private var layout = ShortLayout.split
    @AppStorage(ShortsDefaults.lengthKey) private var length = ShortsPlanner.Length.standard
    @AppStorage(ShortsDefaults.countKey) private var count = 0
    @AppStorage(ShortsDefaults.styleKey) private var styleID = ""
    @State private var expanded: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Make YouTube Shorts")
                if model.hasWebcam { LayoutPicker(selection: $layout) }
                Text("Style").font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.top, 2)
                StyleGrid(styles: model.shortStyles, selectedName: newStyle.name) { styleID = $0.id.uuidString }
                HStack(spacing: 10) {
                    OptionPicker(symbol: "timer", help: "How long each short is", selection: $length) {
                        ForEach(ShortsPlanner.Length.allCases) { Text($0.label).tag($0) }
                    }
                    OptionPicker(symbol: "square.stack", help: "How many shorts to make", selection: $count) {
                        Text("Auto · \(autoCount)").tag(0)
                        Divider()
                        ForEach(1...8, id: \.self) { Text("\($0) short\($0 == 1 ? "" : "s")").tag($0) }
                    }
                }
                Button {
                    model.makeShorts(count: count > 0 ? count : nil, length: length, layout: layout, style: newStyle)
                } label: {
                    HStack(spacing: 6) {
                        if model.shortsBusy { ProgressView().controlSize(.small) } else { Image(systemName: "sparkles") }
                        Text(model.shortsBusy ? "Making shorts…" : makeTitle)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.shortsBusy || model.totalDuration < 10)
                Text(model.shorts.isEmpty
                     ? "Claude picks moments that stand on their own and adds captions, a hook title and post text."
                     : "New shorts skip moments you already have.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(model.shorts.isEmpty ? "Your shorts" : "Your shorts · \(model.shorts.count)") {
                    if !model.shorts.isEmpty {
                        HStack(spacing: 2) {
                            Menu {
                                ForEach(model.shortStyles) { style in Button(style.name) { model.applyStyleToAllShorts(style) } }
                            } label: {
                                Image(systemName: "paintbrush")
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("Give all shorts one style")
                            IconButton(symbol: "folder", help: "Show exported shorts in Finder", action: model.revealShortsFolder)
                            Button { model.exportShorts() } label: {
                                Label("Export All", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .disabled(model.shortsExporting != nil)
                        }
                    }
                }
                if let p = model.shortsExporting { ProgressView(value: p).controlSize(.small) }
                if model.shorts.isEmpty {
                    EmptyState(symbol: "rectangle.portrait.on.rectangle.portrait", text: "Your shorts will show up here.")
                } else {
                    VStack(spacing: 8) {
                        ForEach(model.shorts) { entry in
                            ShortCard(model: model, entry: entry, expanded: Binding(
                                get: { expanded == entry.url },
                                set: { expanded = $0 ? entry.url : nil }))
                        }
                    }
                }
            }
        }
        .onAppear { model.reloadShorts() }
    }

    private var autoCount: Int { ShortsPlanner.autoCount(duration: model.totalDuration) }
    private var newStyle: ShortStyle {
        ShortStyleStore.find(styleID, kits: model.brandKits) ?? ShortsDefaults.style(kits: model.brandKits)
    }
    private var makeTitle: String {
        let n = count > 0 ? count : autoCount
        return "Make \(n) Short\(n == 1 ? "" : "s")"
    }
}

private struct ShortCard: View {
    @ObservedObject var model: EditorModel
    let entry: ShortEntry
    @Binding var expanded: Bool
    @State private var confirmDelete = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(alignment: .top, spacing: 10) {
                    ShortThumbnail(url: entry.url, version: entry.info.exportedAt, width: 42)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.info.title.isEmpty ? "Untitled" : entry.info.title)
                            .font(.callout.weight(.semibold))
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        ShortMeta(index: entry.info.index, duration: entry.duration, exported: entry.info.exportedAt != nil)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .padding(.top, 3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Divider()
                PostEditor(info: Binding(get: { entry.info }, set: { model.updateShort(entry.url, $0) }))
                HStack(spacing: 6) {
                    Button { model.openShort(entry) } label: { Label("Edit Video", systemImage: "slider.horizontal.3") }
                    Button { model.exportShorts([entry]) } label: { Label("Export", systemImage: "square.and.arrow.up") }
                        .disabled(model.shortsExporting != nil)
                    Spacer()
                    IconButton(symbol: "doc.on.doc", help: "Copy title, description and hashtags") { model.copyPostText(entry.info) }
                    IconButton(symbol: "trash", help: "Move this short to the Trash") { confirmDelete = true }
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(expanded ? 0.07 : hovering ? 0.06 : 0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(expanded ? 0.1 : 0)))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Edit Video") { model.openShort(entry) }
            Button("Export") { model.exportShorts([entry]) }
            Button("Copy Post Text") { model.copyPostText(entry.info) }
            Divider()
            Button("Move to Trash", role: .destructive) { model.deleteShort(entry) }
        }
        .confirmationDialog("Move “\(entry.info.title)” to the Trash?", isPresented: $confirmDelete) {
            Button("Move to Trash", role: .destructive) { model.deleteShort(entry) }
        } message: {
            Text("Its project goes to the Trash; exported files stay.")
        }
    }
}

// MARK: - A short

private struct ShortDetail: View {
    @ObservedObject var model: EditorModel
    let info: ShortInfo

    private var current: ShortInfo { model.shortInfo ?? info }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header

            if model.hasWebcam {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader("Layout")
                    LayoutPicker(selection: Binding(get: { model.shortLayout }, set: { model.applyShortLayout($0) }))
                }
            }

            ShortStyleSection(model: model)

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Post") {
                    Button { model.copyPostText(current) } label: { Label("Copy", systemImage: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Copy title, description and hashtags for YouTube Studio")
                }
                PostEditor(info: Binding(get: { current }, set: { model.updateShortInfo($0) }))
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("Export")
                Button { model.exportShorts() } label: {
                    HStack(spacing: 6) {
                        if model.shortsExporting != nil { ProgressView().controlSize(.small) } else { Image(systemName: "square.and.arrow.up") }
                        Text(model.shortsExporting != nil ? "Exporting…" : current.exportedAt == nil ? "Export Short" : "Export Again")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.shortsExporting != nil)
                .help("MP4 plus a .txt with the post text, in Movies › \(ShortStore.safeName(info.parentName)) – Shorts")
                if let p = model.shortsExporting { ProgressView(value: p).controlSize(.small) }
                if let path = current.exportedPath, let at = current.exportedAt {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("Exported \(at.formatted(.relative(presentation: .named)))")
                            Text("·").foregroundStyle(.tertiary)
                            Text("Show in Finder").foregroundStyle(Color.accentColor)
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ShortThumbnail(url: model.project.url, version: current.exportedAt, width: 54)
                VStack(alignment: .leading, spacing: 5) {
                    Text("YOUTUBE SHORT").font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor)
                    Text(current.title.isEmpty ? "Untitled" : current.title)
                        .font(.headline)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    ShortMeta(index: current.index, duration: model.totalDuration, exported: current.exportedAt != nil)
                }
                Spacer(minLength: 0)
            }
            Button(action: model.openOriginal) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.turn.up.left")
                    Text("From “\(info.parentName)”").lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.forward.square").foregroundStyle(.tertiary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open the video this short was cut from")
            ForEach(checks, id: \.self) { warning in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(warning).fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Things that keep a video from working as a Short.
    private var checks: [String] {
        var list: [String] = []
        if model.settings.aspect != .vertical && model.settings.aspect != .square {
            list.append("Not vertical. Pick 9:16 in the Export tab, or YouTube shows it as a normal video.")
        }
        if model.totalDuration > 180 { list.append("Over 3 minutes, so YouTube won't treat it as a Short.") }
        if model.captions.isEmpty { list.append("No captions. Most Shorts are watched without sound.") }
        return list
    }
}

// MARK: - Shared pieces

/// Section title with an optional trailing control.
struct SectionHeader<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            trailing
        }
        .frame(minHeight: 18)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) { self.init(title) { EmptyView() } }
}

/// "#3 · 0:36 · Exported"
private struct ShortMeta: View {
    let index: Int
    let duration: Double
    let exported: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text("#\(index)").foregroundStyle(.tertiary)
            Text(formatDuration(duration)).monospacedDigit()
            if duration > 180 {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help("Over 3 minutes, so YouTube won't treat it as a Short")
            }
            if exported {
                Label("Exported", systemImage: "checkmark")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.green.opacity(0.14), in: Capsule())
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// A rendered frame of a short, 9:16.
private struct ShortThumbnail: View {
    let url: URL
    /// Changes after an export, so the picture refreshes after edits.
    let version: Date?
    var width: CGFloat = 42
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.55))
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "play.rectangle").foregroundStyle(.tertiary)
            }
        }
        .frame(width: width, height: width * 16 / 9)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
        .task(id: "\(url.path)|\(version?.timeIntervalSince1970 ?? 0)") {
            guard let project = try? ProjectStore.load(url) else { return }
            image = try? await Exporter.still(project: project, at: min(1.5, project.totalDuration / 2), maxLongSide: 320)
        }
    }
}

/// Title, description and hashtags of a short.
private struct PostEditor: View {
    @Binding var info: ShortInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Field("Title", count: info.title.count, limit: ShortInfo.titleLimit) {
                TextField("What's the short about?", text: $info.title, axis: .vertical)
                    .lineLimit(1...4)
            }
            Field("Description", count: info.description.count, limit: ShortInfo.descriptionLimit) {
                TextField("A sentence or two for viewers", text: $info.description, axis: .vertical)
                    .lineLimit(3...8)
            }
            Field("Hashtags", count: nil, limit: nil) {
                HashtagEditor(tags: $info.hashtags)
            }
        }
    }
}

/// Label, optional character count, and a boxed control.
private struct Field<Content: View>: View {
    let title: String
    let count: Int?
    let limit: Int?
    let content: Content

    init(_ title: String, count: Int?, limit: Int?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.count = count
        self.limit = limit
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                if let count, let limit, count > limit * 7 / 10 {
                    Text("\(count)/\(limit)").font(.caption2.monospacedDigit())
                        .foregroundStyle(count > limit ? Color.red : Color.secondary)
                }
            }
            content
                .textFieldStyle(.plain)
                .font(.callout)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
        }
    }
}

/// Hashtags as removable chips (#Shorts fixed first), plus a field that turns typed words into chips.
private struct HashtagEditor: View {
    @Binding var tags: [String]
    @State private var draft = ""

    var body: some View {
        FlowLayout(spacing: 5, lineSpacing: 5) {
            chip("Shorts", removable: false)
            ForEach(Array(tags.enumerated()), id: \.offset) { i, tag in
                chip(tag, removable: true) { tags.remove(at: i) }
            }
            TextField(tags.isEmpty ? "Add hashtags" : "Add…", text: $draft)
                .frame(minWidth: 60, maxWidth: 120)
                .onSubmit(commit)
                .onChange(of: draft) { _, text in
                    if text.contains(where: { $0 == " " || $0 == "," }) { commit() }
                }
        }
    }

    private func commit() {
        let new = ShortInfo.parseHashtags(draft).filter { tag in
            tag.caseInsensitiveCompare("Shorts") != .orderedSame
                && !tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
        }
        if !new.isEmpty { tags += new }
        draft = ""
    }

    private func chip(_ tag: String, removable: Bool, remove: @escaping () -> Void = {}) -> some View {
        HStack(spacing: 3) {
            Text("#\(tag)").lineLimit(1)
            if removable {
                Button(action: remove) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove #\(tag)")
            }
        }
        .font(.caption.weight(.medium))
        .padding(.leading, 7)
        .padding(.trailing, removable ? 5 : 7)
        .padding(.vertical, 3)
        .foregroundStyle(removable ? Color.primary : Color.accentColor)
        .background(removable ? Color.primary.opacity(0.08) : Color.accentColor.opacity(0.15), in: Capsule())
        .help(removable ? "" : "Added automatically so YouTube files it under Shorts")
    }
}

/// An icon plus a native pop-up menu.
private struct OptionPicker<Value: Hashable, Content: View>: View {
    let symbol: String
    let help: String
    @Binding var selection: Value
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
            Picker(help, selection: $selection) { content }
                .labelsHidden()
                .pickerStyle(.menu)
        }
        .frame(maxWidth: .infinity)
        .help(help)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 22, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

/// Four layout tiles: Split, Bubble, Camera, Screen, each with a tiny diagram.
private struct LayoutPicker: View {
    @Binding var selection: ShortLayout

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ShortLayout.allCases) { layout in
                let selected = selection == layout
                Button { selection = layout } label: {
                    VStack(spacing: 6) {
                        LayoutDiagram(layout: layout, selected: selected)
                        Text(layout.label).font(.caption.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .background(selected ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(selected ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: selected ? 1.5 : 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(layout.detail)
            }
        }
    }
}

/// A 9:16 sketch of where screen and camera sit: lines stand for screen content, the person for you.
private struct LayoutDiagram: View {
    let layout: ShortLayout
    let selected: Bool

    var body: some View {
        let tint = selected ? Color.accentColor : Color.secondary
        ZStack {
            RoundedRectangle(cornerRadius: 4).strokeBorder(tint.opacity(0.7), lineWidth: 1.2)
            Group {
                switch layout {
                case .split:
                    VStack(spacing: 2) {
                        screen(tint)
                        camera(tint).frame(height: 15)
                    }
                case .bubble:
                    screen(tint)
                        .overlay(alignment: .bottomTrailing) {
                            Circle().fill(tint).frame(width: 9, height: 9)
                                .overlay(Image(systemName: "person.fill").font(.system(size: 5.5)).foregroundStyle(.background))
                                .padding(1.5)
                        }
                case .camera:
                    camera(tint)
                case .screen:
                    screen(tint)
                }
            }
            .padding(2.5)
        }
        .frame(width: 22, height: 38)
    }

    private func screen(_ tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(tint.opacity(0.18))
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Capsule().fill(tint.opacity(0.6)).frame(width: 9, height: 1.6)
                    Capsule().fill(tint.opacity(0.4)).frame(width: 12, height: 1.6)
                    Capsule().fill(tint.opacity(0.4)).frame(width: 7, height: 1.6)
                }
                .padding(3)
            }
    }

    private func camera(_ tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(tint.opacity(0.5))
            .overlay(Image(systemName: "person.fill").font(.system(size: 9)).foregroundStyle(.background.opacity(0.85)))
            .clipped()
    }
}
