import CoreGraphics

/// Pure, testable stitcher for scrolling capture. Estimates how far the content scrolled between
/// two consecutive frames of the same region and appends the newly-revealed strip to a growing
/// canvas. All images are top-left origin, device pixels, the same width.
///
/// Row indexing is top-first (`rows[0]` = visual top row) to match `CGImage.cropping(to:)`, which
/// also uses a top-left origin — keeping the shift math and the append direction consistent.
nonisolated enum ScrollStitcher {
    /// Retained input strips are capped because final compositing temporarily needs a second bitmap
    /// of roughly the same size. This keeps the predictable stitch peak near 512 MiB instead of
    /// allowing a long-running session to grow until the process is jetsammed.
    static let captureBitmapBudgetBytes = 256 * 1_024 * 1_024
    /// A separate dimension backstop protects very narrow selections whose byte count alone would
    /// permit an impractically tall Core Graphics context.
    static let captureHeightLimit = 100_000

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

    /// Whether another independently-backed bitmap can be retained for the eventual composite.
    /// The overflow checks are intentional: dimensions originate in external display content.
    static func canRetain(
        currentBytes: Int,
        currentHeight: Int,
        candidateBytesPerRow: Int,
        candidateHeight: Int,
        byteBudget: Int = captureBitmapBudgetBytes,
        heightLimit: Int = captureHeightLimit
    ) -> Bool {
        guard currentBytes >= 0, currentHeight >= 0,
              candidateBytesPerRow > 0, candidateHeight > 0,
              byteBudget > 0, heightLimit > 0 else { return false }
        let (candidateBytes, byteOverflow) = candidateBytesPerRow.multipliedReportingOverflow(by: candidateHeight)
        let (totalBytes, totalByteOverflow) = currentBytes.addingReportingOverflow(candidateBytes)
        let (totalHeight, heightOverflow) = currentHeight.addingReportingOverflow(candidateHeight)
        return !byteOverflow && !totalByteOverflow && !heightOverflow
            && totalBytes <= byteBudget && totalHeight <= heightLimit
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
        let fineRowStep = max(1, rowStep)

        // If the frames are essentially identical aligned, nothing scrolled.
        if score(prev: prev, next: next, shift: 0, height: h, rowStep: fineRowStep) < staticThreshold { return 0 }

        let overlapMinRows = max(24, h / 5)
        let limit = min(maxShift, h - overlapMinRows)
        guard limit >= minShift else { return 0 }

        // Coarse-to-fine avoids ~100M scalar differences per 4K tick. High-entropy rows do not vary
        // smoothly with shift, so inspect every integer shift but use sparse rows *and* columns;
        // then score only a tiny neighborhood at full density.
        let refinementRadius = 2
        let coarseRowStep = max(8, fineRowStep * 4)
        var coarseBest = minShift
        var coarseScore = Double.greatestFiniteMagnitude
        for dy in minShift...limit {
            let value = score(
                prev: prev, next: next, shift: dy, height: h,
                rowStep: coarseRowStep, columnStep: 4)
            if value < coarseScore { coarseScore = value; coarseBest = dy }
        }

        var bestDy = 0
        var bestScore = Double.greatestFiniteMagnitude
        let lower = max(minShift, coarseBest - refinementRadius)
        let upper = min(limit, coarseBest + refinementRadius)
        for dy in lower...upper {
            let value = score(prev: prev, next: next, shift: dy, height: h, rowStep: fineRowStep)
            if value < bestScore { bestScore = value; bestDy = dy }
        }
        return bestScore < matchThreshold ? bestDy : 0
    }

    /// Mean absolute difference between `next[y]` and `prev[y+shift]` over the overlap.
    private static func score(prev: [[UInt8]], next: [[UInt8]], shift: Int, height h: Int,
                              rowStep: Int, columnStep: Int = 1) -> Double {
        let overlap = h - shift
        guard overlap > 0 else { return .greatestFiniteMagnitude }
        var sum = 0, count = 0
        var y = 0
        while y < overlap {
            let a = next[y], b = prev[y + shift]
            let n = min(a.count, b.count)
            var d = 0
            var sampledColumns = 0
            for c in stride(from: 0, to: n, by: max(1, columnStep)) {
                d += abs(Int(a[c]) - Int(b[c]))
                sampledColumns += 1
            }
            sum += d; count += sampledColumns
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
