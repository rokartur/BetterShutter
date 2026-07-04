import CoreGraphics

/// Pure, testable stitcher for scrolling capture. Estimates how far the content scrolled between
/// two consecutive frames of the same region and appends the newly-revealed strip to a growing
/// canvas. All images are top-left origin, device pixels, the same width.
///
/// Row indexing is top-first (`rows[0]` = visual top row) to match `CGImage.cropping(to:)`, which
/// also uses a top-left origin — keeping the shift math and the append direction consistent.
nonisolated enum ScrollStitcher {
    /// Horizontal downsample width used for cheap row signatures.
    static let columns = 48
    /// Reject matches whose average per-sample difference exceeds this (0–255 scale).
    static let matchThreshold = 14.0
    /// Below this the two frames are considered identical (no scroll) — guards against false shifts.
    static let staticThreshold = 2.5

    /// The cheap grayscale row signature of a frame — all that shift-matching needs. Deliberately
    /// does NOT hold the frame's CGImage, so the previous full-res frame isn't pinned between ticks.
    struct Frame: Sendable {
        let signature: [[UInt8]]
    }

    /// Build a frame signature for matching.
    static func makeFrame(_ image: CGImage) -> Frame? {
        guard let sig = grayRows(image, columns: columns) else { return nil }
        return Frame(signature: sig)
    }

    /// Estimate the downward scroll (in source pixels) from `prev` to `next`. 0 = no usable scroll.
    static func bestShift(prev: [[UInt8]], next: [[UInt8]],
                          maxShift: Int = 1200, minShift: Int = 2, rowStep: Int = 2) -> Int {
        let h = min(prev.count, next.count)
        guard h > 40, let cols = next.first?.count, cols > 0 else { return 0 }

        // If the frames are essentially identical aligned, nothing scrolled.
        if score(prev: prev, next: next, shift: 0, height: h, rowStep: rowStep) < staticThreshold { return 0 }

        let overlapMinRows = max(24, h / 5)
        let limit = min(maxShift, h - overlapMinRows)
        guard limit >= minShift else { return 0 }

        var bestDy = 0
        var bestScore = Double.greatestFiniteMagnitude
        for dy in stride(from: minShift, through: limit, by: 1) {
            let s = score(prev: prev, next: next, shift: dy, height: h, rowStep: rowStep)
            if s < bestScore { bestScore = s; bestDy = dy }
        }
        return bestScore < matchThreshold ? bestDy : 0
    }

    /// Mean absolute difference between `next[y]` and `prev[y+shift]` over the overlap.
    private static func score(prev: [[UInt8]], next: [[UInt8]], shift: Int, height h: Int, rowStep: Int) -> Double {
        let overlap = h - shift
        guard overlap > 0 else { return .greatestFiniteMagnitude }
        var sum = 0, count = 0
        var y = 0
        while y < overlap {
            let a = next[y], b = prev[y + shift]
            let n = min(a.count, b.count)
            var d = 0
            for c in 0..<n { d += abs(Int(a[c]) - Int(b[c])) }
            sum += d; count += n
            y += rowStep
        }
        return count == 0 ? .greatestFiniteMagnitude : Double(sum) / Double(count)
    }

    /// Deep-copy the bottom `rows` visual rows of `next` into a standalone image.
    ///
    /// `cropping(to:)` alone shares — and would pin — the whole source frame's backing store
    /// (~12 MB per tick), so the crop is redrawn into a rows-height bitmap of its own. Strips
    /// accumulate during the session and are composited once at the end, keeping per-tick work
    /// O(strip) instead of re-rendering the whole growing canvas (O(n²) over the session).
    static func strip(from next: CGImage, rows: Int) -> CGImage? {
        guard rows > 0, rows <= next.height else { return nil }
        let w = next.width
        guard let cropped = next.cropping(to: CGRect(x: 0, y: next.height - rows, width: w, height: rows)),
              let ctx = CGContext(
                  data: nil, width: w, height: rows, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(rows)))
        return ctx.makeImage()
    }

    /// Stack `head` then each strip beneath it into one tall image. Called once, at session end.
    static func composite(head: CGImage, strips: [CGImage]) -> CGImage? {
        let w = head.width
        let totalH = head.height + strips.reduce(0) { $0 + $1.height }
        guard strips.allSatisfy({ $0.width == w }),
              let ctx = CGContext(
                  data: nil, width: w, height: totalH, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        // Bottom-left user space: the head goes at the visual top, each strip below the previous.
        var y = totalH - head.height
        ctx.draw(head, in: CGRect(x: 0, y: CGFloat(y), width: CGFloat(w), height: CGFloat(head.height)))
        for strip in strips {
            y -= strip.height
            ctx.draw(strip, in: CGRect(x: 0, y: CGFloat(y), width: CGFloat(w), height: CGFloat(strip.height)))
        }
        return ctx.makeImage()
    }

    // MARK: Helpers

    /// Top-first grayscale row signatures, downsampled to `columns` wide.
    static func grayRows(_ image: CGImage, columns w: Int) -> [[UInt8]]? {
        let h = image.height
        guard w > 0, h > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: w * h)
        let cs = CGColorSpaceCreateDeviceGray()
        let ok: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w, space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            ctx.interpolationQuality = .low
            // A bitmap context's buffer row 0 is already the image's top row, so a plain draw gives
            // top-first signatures — matching CGImage.cropping(to:)'s top-left origin.
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var rows = [[UInt8]]()
        rows.reserveCapacity(h)
        for y in 0..<h {
            let start = y * w
            rows.append(Array(buffer[start..<start + w]))
        }
        return rows
    }
}
