import AVFoundation
import SwiftUI

/// Live input level of the default microphone, shown before recording so a muted or wrong mic
/// is noticed before it ends up as a silent voice track.
@MainActor
final class MicMeter: ObservableObject {
    @Published private(set) var level: Float = 0      // 0…1 (−60…0 dB)
    @Published private(set) var peakDB: Float = -60
    @Published private(set) var deviceName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "No microphone"
    private var engine: AVAudioEngine?

    func start() {
        guard engine == nil, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        deviceName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "No microphone"
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let data = buffer.floatChannelData?[0] else { return }
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
            let rms = sqrt(sum / Float(max(1, buffer.frameLength)))
            let db = max(-60, 20 * log10(max(rms, 0.000_001)))
            Task { @MainActor in
                guard let self else { return }
                self.level = self.level * 0.6 + (db + 60) / 60 * 0.4
                self.peakDB = max(db, self.peakDB - 0.4)
            }
        }
        do {
            try engine.start()
            self.engine = engine
        } catch {
            input.removeTap(onBus: 0)
        }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        level = 0
        peakDB = -60
    }
}

struct MicMeterView: View {
    @StateObject private var meter = MicMeter()
    let active: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.fill").foregroundStyle(.secondary)
            Text(meter.deviceName).font(.caption).lineLimit(1).frame(maxWidth: 150, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(color).frame(width: geo.size.width * CGFloat(min(1, max(0, meter.level))))
                }
            }
            .frame(height: 6)
            Text(hint).font(.caption).foregroundStyle(meter.peakDB < -42 ? Color.orange : Color.secondary)
                .frame(width: 110, alignment: .trailing)
        }
        .onAppear { if active { meter.start() } }
        .onDisappear { meter.stop() }
        .onChange(of: active) { _, on in if on { meter.start() } else { meter.stop() } }
    }

    private var color: Color { meter.peakDB > -6 ? .red : meter.peakDB > -42 ? .green : .orange }

    private var hint: String {
        if meter.peakDB < -50 { return "Speak to test…" }
        if meter.peakDB < -42 { return "Very quiet" }
        return meter.peakDB > -6 ? "Too loud" : "Good level"
    }
}
