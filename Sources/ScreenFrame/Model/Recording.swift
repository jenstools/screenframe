import Foundation

/// Raw capture output. Everything here is written once by the recorder (or importer) and never
/// edited; all effects are derived from it at render time.
///
/// Coordinates are source-video pixels with a top-left origin. Times are seconds from the first
/// video frame.
struct RecordingInfo: Codable {
    var version: Int
    var videoFile: String
    var audio: [AudioTrackInfo]
    var sourceWidth: Double
    var sourceHeight: Double
    /// Source pixels per screen point (2 on Retina). Cursor images are sized in points.
    var pointScale: Double
    var duration: Double
    var mouse: [MouseSample]
    var clicks: [ClickEvent]
    var cursors: [CursorImageInfo]
    /// Window recordings: the window's corner radius in points, so its transparent corners get
    /// masked even with zero padding.
    var cornerRadius: Double?
    /// Camera recorded alongside the screen.
    var webcam: WebcamTrackInfo?
    /// Times of key presses (no key codes), when typing capture was on. Used for "Speed up typing".
    var keystrokes: [Double]?
    /// Where the camera bubble sat on screen while recording (its centre, normalized to the
    /// recorded content, top-left origin), sampled whenever it moved.
    var webcamPath: [WebcamPoint]?
    /// Video times where "Take again" was pressed while recording.
    var retakeMarks: [Double]?
}

struct WebcamPoint: Codable {
    var t: Double
    var x: Double
    var y: Double
}

struct WebcamTrackInfo: Codable {
    var file: String
    /// Video time (seconds) at which the webcam file's first frame plays.
    var offset: Double
    var width: Double
    var height: Double
}

struct MouseSample: Codable {
    var t: Double
    var x: Double
    var y: Double
    /// Cursor image id, nil while the cursor is hidden.
    var c: String?
}

struct ClickEvent: Codable {
    var t: Double
    var x: Double
    var y: Double
    var down: Bool
    /// 0 = left, 1 = right, 2 = other.
    var button: Int
}

struct CursorImageInfo: Codable {
    var id: String
    /// Hot spot in points, top-left origin.
    var hotX: Double
    var hotY: Double
    /// Display size in points.
    var width: Double
    var height: Double
}

struct AudioTrackInfo: Codable {
    var file: String
    /// Video time (seconds) at which this file's first sample plays.
    var offset: Double
    var kind: String
}
