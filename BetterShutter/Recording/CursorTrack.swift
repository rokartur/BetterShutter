import CoreGraphics
import Foundation

/// A timestamped trail of cursor positions sampled during a recording, used by the video editor's
/// "Follow Mouse" auto-zoom. Positions are normalized 0…1 within the recorded display, bottom-left
/// origin (matching CoreImage), so they map straight onto the video frame.
nonisolated struct CursorSample: Codable, Sendable {
    var t: Double    // seconds since recording start
    var x: Double    // 0…1 from left
    var y: Double    // 0…1 from bottom
}

nonisolated struct CursorTrack: Codable, Sendable {
    var samples: [CursorSample]

    var isEmpty: Bool { samples.isEmpty }

    /// The interpolated normalized cursor position at time `t` (clamped to the track's ends).
    func point(at t: Double) -> CGPoint? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if t <= first.t { return CGPoint(x: first.x, y: first.y) }
        if t >= last.t { return CGPoint(x: last.x, y: last.y) }
        // Linear scan is fine (tracks are short and sampled ~20-30 Hz); find the bracketing pair.
        for i in 1..<samples.count {
            let a = samples[i - 1], b = samples[i]
            if t >= a.t && t <= b.t {
                let span = b.t - a.t
                let f = span > 0 ? (t - a.t) / span : 0
                return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
            }
        }
        return CGPoint(x: last.x, y: last.y)
    }

    /// Sidecar file holding the track for a given recording.
    static func sidecarURL(for video: URL) -> URL {
        video.deletingPathExtension().appendingPathExtension("cursor.json")
    }

    func write(for video: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.sidecarURL(for: video))
    }

    static func load(for video: URL) -> CursorTrack? {
        guard let data = try? Data(contentsOf: sidecarURL(for: video)),
              let track = try? JSONDecoder().decode(CursorTrack.self, from: data),
              !track.isEmpty else { return nil }
        return track
    }
}
