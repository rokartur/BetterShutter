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
        // A one-hour track can contain 90k samples, and video export asks for a point once per
        // output frame. A linear scan here turns a long export into billions of comparisons. Find
        // the first sample at-or-after `t` in O(log n), then interpolate with its predecessor.
        var low = 1
        var high = samples.count - 1
        while low < high {
            let mid = low + (high - low) / 2
            if samples[mid].t < t {
                low = mid + 1
            } else {
                high = mid
            }
        }
        let a = samples[low - 1]
        let b = samples[low]
        let span = b.t - a.t
        let f = span > 0 ? (t - a.t) / span : 0
        return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
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
