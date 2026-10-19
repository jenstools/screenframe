import SwiftUI

/// A still of the raw recording with the zoomed-in area drawn on top. Click or drag to move the
/// area; what's inside the frame is what the zoom will show.
struct FocusPicker: View {
    let image: CGImage?
    let aspect: Double
    /// Visible share of the recording at this zoom (0…1 per axis).
    let visible: CGSize
    let point: CGPoint
    let onChange: (CGPoint) -> Void

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let rect = visibleRect(in: size)
            ZStack(alignment: .topLeading) {
                if let image {
                    Image(decorative: image, scale: 1).resizable().frame(width: size.width, height: size.height)
                } else {
                    Rectangle().fill(.quaternary)
                    ProgressView().controlSize(.small).frame(width: size.width, height: size.height)
                }
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size))
                    path.addRect(rect)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.white, lineWidth: 2)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(radius: 1)
                    .position(x: rect.midX, y: rect.midY)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                onChange(clamped(CGPoint(x: value.location.x / size.width, y: value.location.y / size.height)))
            })
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
        .help("Click or drag to choose what the zoom shows")
    }

    /// Keeps the zoom area inside the recording, the same way the camera does when rendering.
    private func clamped(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, visible.width / 2), 1 - visible.width / 2),
                y: min(max(p.y, visible.height / 2), 1 - visible.height / 2))
    }

    private func visibleRect(in size: CGSize) -> CGRect {
        let c = clamped(point)
        let w = visible.width * size.width, h = visible.height * size.height
        return CGRect(x: c.x * size.width - w / 2, y: c.y * size.height - h / 2, width: w, height: h)
    }
}
