import AVKit
import SwiftUI

struct EditorView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                PlayerView(player: model.player)
                    .background(Color(nsColor: .underPageBackgroundColor))
                    .overlay(PreviewOverlay(model: model))
                    .overlay(alignment: .top) { ActivityStrip(model: model) }
                TransportBar(model: model)
                Divider()
                ScrollView(.vertical) {
                    TimelineView(model: model)
                        .frame(height: TimelineView.height(for: model))
                        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in resignTextFocus() })
                        .padding(.vertical, 6)
                }
                .frame(height: min(380, TimelineView.height(for: model) + 12))
            }
            Divider()
            InspectorView(model: model)
                .frame(width: 310)
        }
        .frame(minWidth: 1040, minHeight: 680)
        .sheet(item: $model.activeSheet) { sheet in
            switch sheet {
            case .content: ContentSheet(model: model)
            case .thumbnail: ThumbnailSheet(model: model)
            case .brandKits: BrandKitSheet(model: model)
            }
        }
        .alert("ScreenFrame", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.allowsVideoFrameAnalysis = false
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// Sits on the preview: click toggles playback, click on a text selects it, dragging a text
/// moves it. The selected text gets a dashed outline.
private struct PreviewOverlay: View {
    @ObservedObject var model: EditorModel
    @State private var dragging: (id: UUID, start: CGPoint)?
    @State private var cameraDrag: CGPoint?
    @State private var hoveringCamera = false
    /// Blur box being moved or resized, with its rect when the drag began.
    @State private var blurDrag: (id: UUID, start: CGRect, resize: Bool)?

    private static let handleSize: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let frame = fittedFrame(in: geo.size)
            let bubble = model.cameraBubbleRect.map { viewRect($0, in: frame) }
            let boxes = model.isPlaying && blurDrag == nil ? [] : model.blurBoxes.map { ($0.region, viewRect($0.rect, in: frame)) }
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                ForEach(boxes, id: \.0.id) { region, rect in
                    let selected = model.selection == .blur(region.id)
                    Rectangle()
                        .strokeBorder(selected ? Color.accentColor : Color.white.opacity(region.enabled ? 0.8 : 0.4),
                                      style: StrokeStyle(lineWidth: selected ? 2 : 1.2, dash: selected ? [] : [5, 3]))
                        .shadow(color: .black.opacity(0.5), radius: 1)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)
                    if selected {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor)
                            .frame(width: Self.handleSize, height: Self.handleSize)
                            .offset(x: rect.maxX - Self.handleSize / 2, y: rect.maxY - Self.handleSize / 2)
                            .allowsHitTesting(false)
                    }
                }
                if let bubble, hoveringCamera || cameraDrag != nil {
                    RoundedRectangle(cornerRadius: model.settings.cameraShape == .circle ? bubble.height / 2 : bubble.height * 0.16)
                        .strokeBorder(Color.white, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .shadow(color: .black.opacity(0.5), radius: 1)
                        .frame(width: bubble.width + 6, height: bubble.height + 6)
                        .offset(x: bubble.minX - 3, y: bubble.minY - 3)
                        .allowsHitTesting(false)
                }
                ForEach(model.visibleTexts) { text in
                    if model.selection == .text(text.id) {
                        let rect = textRect(text, in: frame)
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.white, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                            .shadow(color: .black.opacity(0.5), radius: 1)
                            .frame(width: rect.width + 8, height: rect.height + 8)
                            .offset(x: rect.minX - 4, y: rect.minY - 4)
                            .allowsHitTesting(false)
                    }
                }
            }
            .onContinuousHover { phase in
                if case .active(let point) = phase, let bubble {
                    let inside = bubble.contains(point)
                    if inside != hoveringCamera {
                        hoveringCamera = inside
                        if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
                    }
                } else if hoveringCamera {
                    hoveringCamera = false
                    NSCursor.pop()
                }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    resignTextFocus()
                    // Blur boxes first (the selected one, then any), then the camera bubble, then texts.
                    if blurDrag == nil, cameraDrag == nil, dragging == nil, !model.isPlaying {
                        let selected = boxes.first { model.selection == .blur($0.0.id) }
                        let handle = selected.map { CGRect(x: $0.1.maxX - 10, y: $0.1.maxY - 10, width: 20, height: 20) }
                        if let selected, let handle, handle.contains(value.startLocation) {
                            blurDrag = (selected.0.id, CGRect(x: selected.0.x, y: selected.0.y, width: selected.0.w, height: selected.0.h), true)
                        } else if let hit = (selected.map { [$0] } ?? []).first(where: { $0.1.contains(value.startLocation) })
                                    ?? boxes.last(where: { $0.1.contains(value.startLocation) }) {
                            blurDrag = (hit.0.id, CGRect(x: hit.0.x, y: hit.0.y, width: hit.0.w, height: hit.0.h), false)
                        }
                        if let blurDrag { model.selection = .blur(blurDrag.id) }
                    }
                    if let blurDrag, let units = model.sourceUnitsPerOutputPixel, frame.width > 0 {
                        // View points → output pixels → normalized source units.
                        let toOutput = model.canvasSize.width / frame.width
                        let dx = value.translation.width * toOutput * units.width
                        let dy = value.translation.height * toOutput * units.height
                        model.updateBlur(blurDrag.id) { r in
                            if blurDrag.resize {
                                r.w = blurDrag.start.width + dx
                                r.h = blurDrag.start.height + dy
                            } else {
                                r.x = blurDrag.start.minX + dx
                                r.y = blurDrag.start.minY + dy
                            }
                        }
                        return
                    }
                    // The camera bubble wins over texts: drag it anywhere.
                    if cameraDrag == nil, dragging == nil, let bubble, bubble.contains(value.startLocation), frame.width > 0 {
                        cameraDrag = CGPoint(x: (bubble.midX - frame.minX) / frame.width, y: (bubble.midY - frame.minY) / frame.height)
                    }
                    if let start = cameraDrag {
                        model.dragCamera(to: CGPoint(x: start.x + value.translation.width / frame.width,
                                                     y: start.y + value.translation.height / frame.height))
                        return
                    }
                    if dragging == nil {
                        guard let hit = model.visibleTexts.last(where: {
                            textRect($0, in: frame).insetBy(dx: -6, dy: -6).contains(value.startLocation)
                        }) else { return }
                        dragging = (hit.id, CGPoint(x: hit.x, y: hit.y))
                        model.selection = .text(hit.id)
                    }
                    guard let dragging, frame.width > 0 else { return }
                    model.updateText(dragging.id) {
                        $0.x = dragging.start.x + value.translation.width / frame.width
                        $0.y = dragging.start.y + value.translation.height / frame.height
                    }
                }
                .onEnded { value in
                    let moved = abs(value.translation.width) + abs(value.translation.height) > 3
                    if dragging == nil, cameraDrag == nil, blurDrag == nil, !moved { model.togglePlay() }
                    dragging = nil
                    cameraDrag = nil
                    blurDrag = nil
                })
        }
    }

    /// Canvas rect (bottom-left origin, output pixels) → view rect (top-left origin).
    private func viewRect(_ rect: CGRect, in frame: CGRect) -> CGRect {
        let canvas = model.canvasSize
        guard canvas.width > 0 else { return .zero }
        let s = frame.width / canvas.width
        return CGRect(x: frame.minX + rect.minX * s, y: frame.minY + (canvas.height - rect.maxY) * s,
                      width: rect.width * s, height: rect.height * s)
    }

    /// Where the output frame sits inside the player (aspect fit).
    private func fittedFrame(in size: CGSize) -> CGRect {
        let canvas = model.canvasSize
        guard canvas.width > 0, canvas.height > 0, size.width > 0, size.height > 0 else { return .zero }
        let scale = min(size.width / canvas.width, size.height / canvas.height)
        let w = canvas.width * scale, h = canvas.height * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func textRect(_ text: TextOverlay, in frame: CGRect) -> CGRect {
        let scale = frame.height / max(1, model.canvasSize.height)
        let size = TextRenderer.measure(text, canvas: model.canvasSize)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: frame.minX + text.x * frame.width - w / 2, y: frame.minY + text.y * frame.height - h / 2, width: w, height: h)
    }
}

private struct TransportBar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 8) {
            Button(action: model.togglePlay) {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 30, height: 24)
            }
            .help("Play / Pause (Space)")

            Text("\(formatTime(model.currentTime)) / \(formatTime(model.totalDuration))")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            ControlGroup {
                Button(action: model.undo) { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!model.canUndo).help("Undo (⌘Z)")
                Button(action: model.redo) { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!model.canRedo).help("Redo (⇧⌘Z)")
            }
            .fixedSize()

            Divider().frame(height: 18)

            // Add things at the playhead.
            ControlGroup {
                Button(action: model.splitAtPlayhead) { Label("Split", systemImage: "scissors") }
                    .help("Split the clip at the playhead (B)")
                Button(action: model.addText) { Label("Text", systemImage: "textformat") }
                    .help("Add a text at the playhead (T)")
                Button(action: model.addZoom) { Label("Zoom", systemImage: "plus.magnifyingglass") }
                    .help("Add a zoom at the playhead")
                if model.hasWebcam {
                    Button { model.addCameraKey() } label: { Label("Camera", systemImage: "video.badge.plus") }
                        .help("Add a camera keyframe at the playhead")
                }
                Button(action: model.addClips) { Label(model.importing ? "Adding…" : "Clip", systemImage: "plus.rectangle.on.rectangle") }
                    .disabled(model.importing)
                    .help("Append video files or other ScreenFrame recordings")
            }
            .labelStyle(.titleAndIcon)
            .fixedSize()

            Button(action: model.toggleZooms) {
                Image(systemName: model.settings.autoZoom ? "eye" : "eye.slash")
            }
            .help(model.settings.autoZoom ? "Zooms are on. Turn all off (Z)" : "Zooms are off. Turn all on (Z)")

            Divider().frame(height: 18)

            Button(action: model.export) { Label("Export", systemImage: "square.and.arrow.up") }
                .buttonStyle(.borderedProminent)
                .disabled(model.exportProgress != nil)
                .keyboardShortcut("e", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

func formatTime(_ seconds: Double) -> String {
    let s = max(0, seconds)
    return String(format: "%d:%02d.%d", Int(s) / 60, Int(s) % 60, Int((s * 10).truncatingRemainder(dividingBy: 10)))
}

/// Takes keyboard focus away from text fields, so Space and the editor shortcuts work again.
@MainActor
func resignTextFocus() {
    guard let window = NSApp.keyWindow, window.firstResponder is NSText else { return }
    window.makeFirstResponder(nil)
}
