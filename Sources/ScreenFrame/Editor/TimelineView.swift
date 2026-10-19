import SwiftUI

/// Ruler, then lanes: clips (select, trim by dragging edges), zooms, titles and captions (select,
/// move, resize) and one waveform lane per audio source. Everything has a right-click menu.
struct TimelineView: View {
    @ObservedObject var model: EditorModel
    @State private var drag: Drag?

    private struct Drag {
        enum Mode { case move, left, right }
        let id: UUID
        let a: Double
        let b: Double
        let mode: Mode
    }

    static let gutter: CGFloat = 92
    private static let trailing: CGFloat = 16
    private static let rulerHeight: CGFloat = 22
    private static let spacing: CGFloat = 6
    private static let clipHeight: CGFloat = 40
    private static let zoomHeight: CGFloat = 28
    private static let textHeight: CGFloat = 26
    private static let audioHeight: CGFloat = 30

    private static let speeds: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4]
    private static let volumes: [Double] = [0, 0.25, 0.5, 0.75, 1]

    static func height(for model: EditorModel) -> CGFloat {
        var lanes = clipHeight + zoomHeight + textHeight + spacing * 3
        if model.hasWebcam { lanes += textHeight + spacing }
        if !model.captions.isEmpty { lanes += textHeight + spacing }
        if !model.blurs.isEmpty { lanes += textHeight + spacing }
        lanes += CGFloat(model.audioLanes.count) * (audioHeight + spacing)
        return rulerHeight + 4 + lanes + 6
    }

    private var showsCaptions: Bool { !model.captions.isEmpty }
    private var showsCamera: Bool { model.hasWebcam }
    private var showsBlurs: Bool { !model.blurs.isEmpty }
    private var clipY: CGFloat { Self.rulerHeight + 4 }
    private var zoomY: CGFloat { clipY + Self.clipHeight + Self.spacing }
    private var cameraY: CGFloat { zoomY + Self.zoomHeight + Self.spacing }
    private var textY: CGFloat { showsCamera ? cameraY + Self.textHeight + Self.spacing : cameraY }
    private var captionY: CGFloat { textY + Self.textHeight + Self.spacing }
    private var blurY: CGFloat { showsCaptions ? captionY + Self.textHeight + Self.spacing : captionY }
    private func audioY(_ i: Int) -> CGFloat {
        (showsBlurs ? blurY + Self.textHeight + Self.spacing : blurY) + CGFloat(i) * (Self.audioHeight + Self.spacing)
    }

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width - Self.gutter - Self.trailing)
            let total = max(model.totalDuration, 0.1)
            let scale = width / total
            let placements = model.placements
            let lanes = model.audioLanes
            ZStack(alignment: .topLeading) {
                gutterLabels(lanes: lanes)

                ruler(scale: scale, total: total)
                    .frame(width: width, height: Self.rulerHeight)
                    .offset(x: Self.gutter, y: 2)
                // The gesture must come before .offset: after it, locations are measured from the
                // un-shifted frame and the playhead lands a gutter's width right of the click.
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: width + Self.trailing, height: Self.rulerHeight + 4)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in model.seek(to: value.location.x / scale) })
                    .offset(x: Self.gutter)

                laneBackground(y: zoomY, height: Self.zoomHeight, width: width, scale: scale)
                if showsCamera {
                    laneBackground(y: cameraY, height: Self.textHeight, width: width, scale: scale)
                        .contextMenu {
                            Button("Add Camera Keyframe at Playhead") { model.addCameraKey() }
                            Button("Auto Layout (full screen while talking)") { model.autoCameraLayout() }
                            if !model.cameraKeys.isEmpty {
                                Divider()
                                Button("Remove All Keyframes", role: .destructive) { model.removeCameraKeys() }
                            }
                        }
                }
                laneBackground(y: textY, height: Self.textHeight, width: width, scale: scale)
                if showsCaptions { laneBackground(y: captionY, height: Self.textHeight, width: width, scale: scale) }
                if showsBlurs { laneBackground(y: blurY, height: Self.textHeight, width: width, scale: scale) }
                ForEach(Array(lanes.enumerated()), id: \.element) { i, kind in
                    audioLane(kind, placements: placements, scale: scale)
                        .frame(width: width, height: Self.audioHeight)
                        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                        .offset(x: Self.gutter, y: audioY(i))
                        .allowsHitTesting(false)
                    ForEach(placements, id: \.clip.id) { p in audioSegment(p, kind: kind, y: audioY(i), scale: scale) }
                }

                ForEach(placements, id: \.clip.id) { p in clipBlock(p, scale: scale) }
                ForEach(placements.filter { $0.overlapOut > 0 }, id: \.clip.id) { p in transitionMarker(p, scale: scale) }
                ForEach(model.placedZooms) { z in zoomBlock(z, scale: scale) }
                ForEach(model.titles) { t in textBlock(t, y: textY, scale: scale) }
                if showsCaptions { ForEach(model.captions) { t in textBlock(t, y: captionY, scale: scale) } }
                if showsCamera { cameraLane(scale: scale) }
                if showsBlurs { blurLane(scale: scale) }
                ForEach(model.cutSuggestions) { cut in cutOverlay(cut, scale: scale, height: geo.size.height) }

                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2, height: geo.size.height - 4)
                    .offset(x: Self.gutter + model.currentTime * scale - 1, y: 2)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: Lanes

    private func gutterLabels(lanes: [String]) -> some View {
        ZStack(alignment: .topLeading) {
            label("Clips", "film.stack", y: clipY, height: Self.clipHeight)
            label("Zoom", "plus.magnifyingglass", y: zoomY, height: Self.zoomHeight)
            label("Text", "textformat", y: textY, height: Self.textHeight)
            if showsCamera { label("Camera", "video", y: cameraY, height: Self.textHeight) }
            if showsCaptions { label("Captions", "captions.bubble", y: captionY, height: Self.textHeight) }
            if showsBlurs { label("Privacy", "eye.slash", y: blurY, height: Self.textHeight) }
            ForEach(Array(lanes.enumerated()), id: \.element) { i, kind in
                HStack(spacing: 4) {
                    Button { model.toggleMute(kind) } label: {
                        Image(systemName: model.isMuted(kind) ? "speaker.slash.fill" : EditorModel.laneSymbol(kind))
                            .foregroundStyle(model.isMuted(kind) ? Color.red : Color.secondary)
                            .frame(width: 16)
                    }
                    .buttonStyle(.plain)
                    .help(model.isMuted(kind) ? "Unmute" : "Mute")
                    Text(kind == "system-audio" ? "System" : EditorModel.laneName(kind)).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: Self.gutter - 12, height: Self.audioHeight, alignment: .leading)
                .offset(x: 10, y: audioY(i))
            }
        }
    }

    private func label(_ title: String, _ symbol: String, y: CGFloat, height: CGFloat) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: Self.gutter - 12, height: height, alignment: .leading)
            .offset(x: 10, y: y)
    }

    /// Clicking empty lane space deselects and moves the playhead there.
    private func laneBackground(y: CGFloat, height: CGFloat, width: CGFloat, scale: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.secondary.opacity(0.07))
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                model.selection = nil
                model.seek(to: value.location.x / scale)
            })
            .offset(x: Self.gutter, y: y)
    }

    private func audioLane(_ kind: String, placements: [EditorModel.Placement], scale: CGFloat) -> some View {
        let muted = model.isMuted(kind)
        let laneVolume = model.volume(kind)
        let color: Color = muted ? .gray.opacity(0.5)
            : kind == "microphone" ? Color(hex: 0x30D158) : kind == "system-audio" ? Color(hex: 0x64D2FF) : Color(hex: 0xFFD60A)
        let waveforms = model.waveforms
        return Canvas { ctx, size in
            for p in placements {
                let volume = muted ? 1 : laneVolume * p.clip.volume(for: kind)
                for audio in p.media.info.audio where audio.kind == kind {
                    guard let peaks = waveforms[p.media.folder.appendingPathComponent(audio.file).path], !peaks.isEmpty else { continue }
                    let x0 = p.offset * scale, x1 = p.end * scale
                    ctx.fill(Path(roundedRect: CGRect(x: x0 + 1, y: 2, width: max(0, x1 - x0 - 2), height: size.height - 4), cornerRadius: 4),
                             with: .color(color.opacity(0.12)))
                    let perSecond = Double(Waveform.perSecond)
                    var x = x0
                    while x < x1 {
                        // Timeline x → source time (speed) → audio file time.
                        let from = p.clip.start + (x - x0) / scale * p.speed - audio.offset
                        let to = from + 2 / scale * p.speed
                        let i0 = max(0, Int(from * perSecond)), i1 = min(peaks.count, Int(to * perSecond) + 1)
                        if i0 < i1 {
                            let amp = Double(peaks[i0..<i1].max() ?? 0) * volume
                            let h = max(1, amp * (size.height - 6))
                            ctx.fill(Path(CGRect(x: x, y: (size.height - h) / 2, width: 1.4, height: h)), with: .color(color))
                        }
                        x += 2
                    }
                }
            }
        }
    }

    /// Invisible per-clip region of an audio lane, for its right-click volume menu.
    @ViewBuilder
    private func audioSegment(_ p: EditorModel.Placement, kind: String, y: CGFloat, scale: CGFloat) -> some View {
        if p.media.info.audio.contains(where: { $0.kind == kind }) {
            let id = p.clip.id
            Color.clear
                .contentShape(Rectangle())
                .frame(width: max(4, p.duration * scale), height: Self.audioHeight)
                .onTapGesture { model.selection = .clip(id) }
                .contextMenu {
                    Picker("\(EditorModel.laneName(kind)) Volume in “\(p.clip.name)”",
                           selection: Binding(get: { p.clip.volume(for: kind) }, set: { model.setClipVolume(id, kind: kind, $0) })) {
                        ForEach(Self.volumes, id: \.self) { Text(Self.volumeLabel($0)).tag($0) }
                    }
                    Divider()
                    Button(model.isMuted(kind) ? "Unmute \(EditorModel.laneName(kind)) Everywhere" : "Mute \(EditorModel.laneName(kind)) Everywhere") {
                        model.toggleMute(kind)
                    }
                }
                .offset(x: Self.gutter + p.offset * scale, y: y)
                .help("Right-click to change this clip's \(EditorModel.laneName(kind).lowercased()) volume")
        }
    }

    // MARK: Blocks

    private func clipBlock(_ p: EditorModel.Placement, scale: CGFloat) -> some View {
        let selected = model.selection == .clip(p.clip.id)
        let width = max(8, p.duration * scale)
        let colors: [Color] = p.clip.kind == .recording ? [Color(hex: 0x4A5578), Color(hex: 0x353C57)] : [Color(hex: 0x1F6F74), Color(hex: 0x17565A)]
        let clicks = p.media.info.clicks.filter { $0.down && $0.t >= p.clip.start && $0.t < p.clip.end }
        let quiet = model.audioKinds(of: p).allSatisfy { p.clip.volume(for: $0) == 0 } && !model.audioKinds(of: p).isEmpty
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 7).fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            ForEach(Array(clicks.enumerated()), id: \.offset) { _, click in
                Circle().fill(Color.orange.opacity(0.9)).frame(width: 5, height: 5)
                    .offset(x: (click.t - p.clip.start) / p.speed * scale - 2.5, y: 10)
            }
            if width > 60 {
                HStack(spacing: 5) {
                    Image(systemName: p.clip.kind == .recording ? "record.circle" : "film")
                    Text(p.clip.name).lineLimit(1)
                    if abs(p.speed - 1) > 0.001 { badge(Self.speedLabel(p.speed)) }
                    if quiet { Image(systemName: "speaker.slash.fill").opacity(0.8) }
                    if p.media.info.webcam != nil { Image(systemName: p.clip.camera == .hidden ? "video.slash" : "video").opacity(0.8) }
                    Spacer(minLength: 4)
                    Text(formatDuration(p.duration)).monospacedDigit().opacity(0.7)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .offset(y: -6)
            }
            RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Color.white : Color.black.opacity(0.25), lineWidth: selected ? 2 : 1)
            HStack(spacing: 0) {
                handle(visible: selected).gesture(dragGesture(id: p.clip.id, a: p.clip.start, b: p.clip.end, mode: .left, scale: scale) { d, delta in
                    model.trimClip(p.clip.id, start: d.a + delta * p.speed)
                })
                Spacer(minLength: 0)
                handle(visible: selected).gesture(dragGesture(id: p.clip.id, a: p.clip.start, b: p.clip.end, mode: .right, scale: scale) { d, delta in
                    model.trimClip(p.clip.id, end: d.b + delta * p.speed)
                })
            }
        }
        .frame(width: width, height: Self.clipHeight)
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { value in
            model.selection = .clip(p.clip.id)
            model.seek(to: p.offset + value.location.x / scale)
        })
        .contextMenu { clipMenu(p) }
        .offset(x: Self.gutter + p.offset * scale, y: clipY)
        .help("\(p.clip.name): click to select, drag the edges to trim, right-click for speed, volume and more")
    }

    @ViewBuilder
    private func clipMenu(_ p: EditorModel.Placement) -> some View {
        let id = p.clip.id
        Picker("Speed", selection: Binding(get: { p.clip.speed }, set: { model.setSpeed(id, $0) })) {
            ForEach(Self.speeds, id: \.self) { Text(Self.speedLabel($0)).tag($0) }
        }
        let kinds = model.audioKinds(of: p)
        if !kinds.isEmpty {
            Menu("Volume") {
                ForEach(kinds, id: \.self) { kind in
                    Picker(EditorModel.laneName(kind), selection: Binding(get: { p.clip.volume(for: kind) },
                                                                          set: { model.setClipVolume(id, kind: kind, $0) })) {
                        ForEach(Self.volumes, id: \.self) { Text(Self.volumeLabel($0)).tag($0) }
                    }
                }
            }
        }
        if p.media.info.webcam != nil {
            Picker("Camera", selection: Binding(get: { p.clip.camera }, set: { model.setCameraLayout(id, $0) })) {
                ForEach(Clip.CameraLayout.allCases) { Text($0.label).tag($0) }
            }
        }
        if p.index < model.clips.count - 1 {
            Picker("Transition to Next", selection: Binding(get: { p.clip.transition?.kind }, set: { model.setTransition(id, $0) })) {
                Text("None").tag(ClipTransition.Kind?.none)
                ForEach(ClipTransition.Kind.allCases) { Text($0.label).tag(Optional($0)) }
            }
        }
        let typing = model.typingRanges(in: p)
        if !typing.isEmpty {
            Button("Speed Up Typing (\(typing.count)× at \(Self.speedLabel(model.settings.typingSpeed)))") { model.speedUpTyping(id) }
        }
        Divider()
        Button("Split at Playhead") { model.split() }
            .disabled(model.currentTime <= p.offset + 0.1 || model.currentTime >= p.end - 0.1)
        Button("Duplicate") { model.duplicateClip(id) }
        Button("Move Earlier") { model.moveClip(id, by: -1) }.disabled(p.index == 0)
        Button("Move Later") { model.moveClip(id, by: 1) }.disabled(p.index >= model.clips.count - 1)
        Divider()
        Button("Delete Clip", role: .destructive) {
            model.selection = .clip(id)
            model.deleteSelection()
        }
        .disabled(model.clips.count < 2)
    }

    private func transitionMarker(_ p: EditorModel.Placement, scale: CGFloat) -> some View {
        let id = p.clip.id
        let width = max(14, p.overlapOut * scale)
        return ZStack {
            Capsule().fill(Color.white.opacity(0.9))
            Image(systemName: p.clip.transition?.kind == .slide ? "arrow.left.square" : "circle.lefthalf.filled")
                .font(.system(size: 9, weight: .bold)).foregroundStyle(.black.opacity(0.75))
        }
        .frame(width: width, height: 14)
        .contextMenu {
            Picker("Transition", selection: Binding(get: { p.clip.transition?.kind }, set: { model.setTransition(id, $0) })) {
                Text("None").tag(ClipTransition.Kind?.none)
                ForEach(ClipTransition.Kind.allCases) { Text($0.label).tag(Optional($0)) }
            }
            Picker("Duration", selection: Binding(get: { p.clip.transition?.duration ?? 0.6 }, set: { model.setTransitionDuration(id, $0) })) {
                ForEach([0.3, 0.6, 1.0, 1.5], id: \.self) { Text(String(format: "%.1f s", $0)).tag($0) }
            }
        }
        .offset(x: Self.gutter + (p.end - p.overlapOut) * scale, y: clipY + Self.clipHeight - 16)
        .help("\(p.clip.transition?.kind.label ?? "Transition"): right-click to change")
    }

    private func zoomBlock(_ z: EditorModel.PlacedZoom, scale: CGFloat) -> some View {
        let clipID = z.placement.clip.id, zoomID = z.segment.id
        let selected = model.selection == .zoom(clip: clipID, zoom: zoomID)
        let active = z.segment.enabled && model.settings.autoZoom
        let speed = z.placement.speed
        return block(x: z.start * scale, width: (z.end - z.start) * scale, y: zoomY, height: Self.zoomHeight,
                     color: active ? Color(hex: 0x7F5AF0) : .gray, selected: selected,
                     label: String(format: "%.1f×", z.segment.zoom),
                     symbol: z.segment.focus == nil ? "plus.magnifyingglass" : "scope",
                     onSelect: { model.selection = .zoom(clip: clipID, zoom: zoomID) },
                     drag: { mode in
                         dragGesture(id: zoomID, a: z.segment.start, b: z.segment.end, mode: mode, scale: scale) { d, delta in
                             model.selection = .zoom(clip: clipID, zoom: zoomID)
                             let shift = delta * speed
                             model.updateZoom(clip: clipID, zoom: zoomID) { s in
                                 switch d.mode {
                                 case .move: s.start = d.a + shift; s.end = d.b + shift
                                 case .left: s.start = min(d.a + shift, d.b - 0.3)
                                 case .right: s.end = max(d.b + shift, d.a + 0.3)
                                 }
                             }
                         }
                     })
            .contextMenu {
                Picker("Zoom Level", selection: Binding(get: { z.segment.zoom }, set: { v in model.updateZoom(clip: clipID, zoom: zoomID) { $0.zoom = v } })) {
                    ForEach([1.25, 1.5, 1.8, 2.0, 2.5, 3.0], id: \.self) { Text(String(format: "%.2g×", $0)).tag($0) }
                }
                Picker("Focus", selection: Binding(get: { z.segment.focus == nil }, set: { follow in
                    let point = follow ? nil : model.defaultFocus(for: z)
                    model.updateZoom(clip: clipID, zoom: zoomID) { $0.focus = point }
                })) {
                    Text("Follow Cursor").tag(true)
                    Text("Fixed Point").tag(false)
                }
                Toggle("Enabled", isOn: Binding(get: { z.segment.enabled }, set: { v in model.updateZoom(clip: clipID, zoom: zoomID) { $0.enabled = v } }))
                Divider()
                Button("Duplicate") { model.duplicateZoom(clip: clipID, zoom: zoomID) }
                Button("Delete Zoom", role: .destructive) {
                    model.selection = .zoom(clip: clipID, zoom: zoomID)
                    model.deleteSelection()
                }
            }
    }

    private func textBlock(_ t: TextOverlay, y: CGFloat, scale: CGFloat) -> some View {
        block(x: t.start * scale, width: (t.end - t.start) * scale, y: y, height: Self.textHeight,
              color: t.caption ? Color(hex: 0x8E8E93) : Color(hex: 0xFF9F0A), selected: model.selection == .text(t.id),
              label: t.text.replacingOccurrences(of: "\n", with: " "), symbol: t.caption ? "captions.bubble" : "textformat",
              onSelect: { model.selection = .text(t.id) },
              drag: { mode in
                  dragGesture(id: t.id, a: t.start, b: t.end, mode: mode, scale: scale) { d, delta in
                      model.selection = .text(t.id)
                      model.updateText(t.id) { s in
                          switch d.mode {
                          case .move:
                              let length = d.b - d.a
                              s.start = min(max(0, d.a + delta), model.totalDuration - length)
                              s.end = s.start + length
                          case .left: s.start = min(d.a + delta, d.b - 0.3)
                          case .right: s.end = max(d.b + delta, d.a + 0.3)
                          }
                      }
                  }
              })
            .contextMenu {
                Picker("Style", selection: Binding(get: { t.style }, set: { v in model.updateText(t.id) { $0.style = v } })) {
                    ForEach(TextOverlay.Style.allCases) { Text($0.label).tag($0) }
                }
                Picker("Size", selection: Binding(get: { t.size }, set: { v in model.updateText(t.id) { $0.size = v } })) {
                    Text("Small").tag(0.035)
                    Text("Medium").tag(0.055)
                    Text("Large").tag(0.08)
                    Text("Huge").tag(0.11)
                }
                Divider()
                if t.caption { Button("Edit & Correct All Subtitles…") { model.openSubtitleEditor?() } }
                Button("Duplicate") { model.duplicateText(t.id) }
                Button(t.caption ? "Delete Caption" : "Delete Text", role: .destructive) {
                    model.selection = .text(t.id)
                    model.deleteSelection()
                }
            }
    }

    // MARK: Camera, privacy and cut lanes

    private func cameraLane(scale: CGFloat) -> some View {
        let keys = model.cameraKeys.sorted { $0.t < $1.t }
        return ZStack(alignment: .topLeading) {
            // Bars show the layout in effect between keyframes.
            ForEach(Array(keys.enumerated()), id: \.element.id) { i, key in
                let end = i + 1 < keys.count ? keys[i + 1].t : model.totalDuration
                RoundedRectangle(cornerRadius: 2)
                    .fill(Self.layoutColor(key.layout ?? .overlay).opacity(0.45))
                    .frame(width: max(2, (end - key.t) * scale), height: 6)
                    .offset(x: Self.gutter + key.t * scale, y: cameraY + Self.textHeight / 2 - 3)
                    .allowsHitTesting(false)
            }
            ForEach(keys) { key in cameraDiamond(key, scale: scale) }
        }
    }

    private func cameraDiamond(_ key: CameraKey, scale: CGFloat) -> some View {
        let selected = model.selection == .cameraKey(key.id)
        return Rectangle()
            .fill(Self.layoutColor(key.layout ?? .overlay))
            .frame(width: 11, height: 11)
            .overlay(Rectangle().strokeBorder(selected ? Color.white : Color.black.opacity(0.4),
                                              style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: key.auto == true ? [2, 2] : [])))
            .rotationEffect(.degrees(45))
            .frame(width: 18, height: Self.textHeight)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { value in
                    if drag?.id != key.id { drag = Drag(id: key.id, a: key.t, b: key.t, mode: .move) }
                    guard let drag else { return }
                    model.selection = .cameraKey(key.id)
                    model.updateCameraKey(key.id) { $0.t = drag.a + value.translation.width / scale }
                }
                .onEnded { _ in drag = nil })
            .onTapGesture {
                model.selection = .cameraKey(key.id)
                model.seek(to: key.t)
            }
            .contextMenu {
                Picker("Layout", selection: Binding(get: { key.layout ?? .overlay }, set: { v in model.updateCameraKey(key.id) { $0.layout = v } })) {
                    ForEach(Clip.CameraLayout.allCases) { Text($0.label).tag($0) }
                }
                Menu("Position") {
                    ForEach(Self.positions, id: \.name) { item in
                        Button(item.name) { model.updateCameraKey(key.id) { $0.x = item.x; $0.y = item.y } }
                    }
                }
                Divider()
                Button("Delete Keyframe", role: .destructive) {
                    model.selection = .cameraKey(key.id)
                    model.deleteSelection()
                }
            }
            .offset(x: Self.gutter + key.t * scale - 9, y: cameraY)
            .help("Camera keyframe: drag to move in time, right-click for layout and position")
    }

    static let positions: [(name: String, x: Double, y: Double)] = [
        ("Top Left", 0.15, 0.2), ("Top Right", 0.85, 0.2), ("Center", 0.5, 0.5), ("Bottom Left", 0.15, 0.8), ("Bottom Right", 0.85, 0.8),
    ]

    static func layoutColor(_ layout: Clip.CameraLayout) -> Color {
        switch layout {
        case .overlay: return Color(hex: 0x64D2FF)
        case .fullscreen: return Color(hex: 0xFF9F0A)
        case .hidden: return .gray
        }
    }

    private func blurLane(scale: CGFloat) -> some View {
        let items: [(region: BlurRegion, span: ClosedRange<Double>, key: String)] = model.blurs.flatMap { region in
            model.timelineSpans(of: region).enumerated().map { (region, $0.element, "\(region.id)-\($0.offset)") }
        }
        return ZStack(alignment: .topLeading) {
            ForEach(items, id: \.key) { item in blurBlock(item.region, span: item.span, scale: scale) }
        }
    }

    private func blurBlock(_ region: BlurRegion, span: ClosedRange<Double>, scale: CGFloat) -> some View {
        let selected = model.selection == .blur(region.id)
        let color: Color = region.enabled ? Color(hex: 0xFF375F).opacity(selected ? 1 : 0.65) : Color.gray.opacity(0.4)
        let width = max(4, (span.upperBound - span.lowerBound) * scale)
        return RoundedRectangle(cornerRadius: 4)
            .fill(color)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? Color.white : .clear, lineWidth: 1.5))
            .frame(width: width, height: Self.textHeight - 8)
            .contentShape(Rectangle())
            .onTapGesture { model.selection = .blur(region.id) }
            .contextMenu { blurMenu(region) }
            .offset(x: Self.gutter + span.lowerBound * scale, y: blurY + 4)
            .help("\(region.kind.label): \(region.label ?? "")")
    }

    @ViewBuilder
    private func blurMenu(_ region: BlurRegion) -> some View {
        Toggle("Blurred", isOn: Binding(get: { region.enabled }, set: { v in model.updateBlur(region.id) { $0.enabled = v } }))
        Button("Turn Off All \(region.kind.label)") { model.setBlurs(region.kind, enabled: false) }
        Divider()
        Button("Delete", role: .destructive) {
            model.selection = .blur(region.id)
            model.deleteSelection()
        }
    }

    /// A proposed cut: red shade over all lanes; the strip on top removes it from the proposal.
    private func cutOverlay(_ cut: CutSuggestion, scale: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.red.opacity(0.22))
                .frame(width: max(2, (cut.end - cut.start) * scale), height: max(0, height - clipY - 4))
                .offset(x: Self.gutter + cut.start * scale, y: clipY)
                .allowsHitTesting(false)
            Rectangle()
                .fill(Color.red.opacity(0.85))
                .frame(width: max(4, (cut.end - cut.start) * scale), height: 5)
                .contentShape(Rectangle())
                .onTapGesture { model.cutSuggestions.removeAll { $0.id == cut.id } }
                .offset(x: Self.gutter + cut.start * scale, y: clipY - 6)
                .help("\(cut.reason): will be cut. Click to keep it.")
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.white.opacity(0.25), in: Capsule())
    }

    static func speedLabel(_ speed: Double) -> String {
        speed == speed.rounded() ? String(format: "%.0f×", speed) : String(format: "%.2g×", speed)
    }

    static func volumeLabel(_ volume: Double) -> String {
        volume == 0 ? "Muted" : "\(Int(volume * 100))%"
    }

    private func block<G: Gesture>(x: CGFloat, width: CGFloat, y: CGFloat, height: CGFloat, color: Color, selected: Bool,
                                   label: String, symbol: String, onSelect: @escaping () -> Void,
                                   drag: @escaping (Drag.Mode) -> G) -> some View {
        let width = max(10, width)
        return ZStack {
            RoundedRectangle(cornerRadius: 6).fill(color.opacity(selected ? 1 : 0.78))
            RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.white : .clear, lineWidth: 1.5)
            if width > 34 {
                Label(label, systemImage: symbol)
                    .font(.caption.bold()).foregroundStyle(.white).lineLimit(1)
                    .padding(.horizontal, 8)
            }
            HStack(spacing: 0) {
                handle(visible: false).gesture(drag(.left))
                Spacer(minLength: 0)
                handle(visible: false).gesture(drag(.right))
            }
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .gesture(drag(.move))
        .onTapGesture(perform: onSelect)
        .offset(x: Self.gutter + x, y: y)
    }

    private func handle(visible: Bool) -> some View {
        Rectangle()
            .fill(visible ? Color.white.opacity(0.85) : Color.white.opacity(0.001))
            .frame(width: visible ? 5 : 9)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .padding(.vertical, visible ? 8 : 0)
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
    }

    private func dragGesture(id: UUID, a: Double, b: Double, mode: Drag.Mode, scale: CGFloat,
                             apply: @escaping (Drag, Double) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if drag?.id != id || drag?.mode != mode { drag = Drag(id: id, a: a, b: b, mode: mode) }
                guard let drag else { return }
                apply(drag, value.translation.width / scale)
            }
            .onEnded { _ in drag = nil }
    }

    private func ruler(scale: CGFloat, total: Double) -> some View {
        Canvas { context, size in
            let steps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
            let step = steps.first { $0 * scale >= 70 } ?? 600
            var t = 0.0
            while t <= total + 0.001 {
                let x = t * scale
                context.fill(Path(CGRect(x: x, y: size.height - 6, width: 1, height: 6)), with: .color(.secondary.opacity(0.6)))
                context.draw(Text(formatDuration(t)).font(.system(size: 9.5, design: .monospaced)).foregroundColor(.secondary),
                             at: CGPoint(x: x + 3, y: 4), anchor: .topLeading)
                t += step
            }
        }
    }
}
