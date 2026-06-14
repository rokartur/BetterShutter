import AVFoundation
import CoreImage
import AppKit

/// Re-composites a recording onto a padded background (Snapzy-style video framing) and exports it,
/// optionally to custom dimensions and trimmed to a range. A GPU CIFilter pass scales each frame
/// down with padding and lays it over a static background image.
enum VideoBeautify {

    /// Pure layout math (testable): from the source pixel size, padding fraction, and an optional
    /// target output height, compute the render size, the scale applied to the video, and the inset.
    nonisolated static func layout(srcW: CGFloat, srcH: CGFloat, paddingFraction: CGFloat,
                                   targetHeight: CGFloat?) -> (renderSize: CGSize, innerScale: CGFloat, inset: CGFloat) {
        let pad = max(0, paddingFraction) * min(srcW, srcH)
        var renderW = srcW + 2 * pad
        var renderH = srcH + 2 * pad
        var innerScale: CGFloat = 1
        var inset = pad
        if let target = targetHeight, target > 0, renderH > 0 {
            let k = target / renderH
            renderW *= k; renderH *= k; innerScale = k; inset *= k
        }
        // H.264 wants even dimensions.
        func even(_ v: CGFloat) -> CGFloat { let i = Int(v.rounded()); return CGFloat(i % 2 == 0 ? i : i - 1) }
        return (CGSize(width: even(renderW), height: even(renderH)), innerScale, inset)
    }

    struct Options {
        var background: BackgroundFill
        var paddingFraction: CGFloat
        var targetHeight: CGFloat?   // nil = native (padded) size
        var cursorTrack: CursorTrack?  // for Follow-Mouse auto-zoom
        var followZoom: CGFloat = 1    // 1 = off
    }

    /// Zoom into `image` by `zoom`, centered on the normalized `focus` (0…1, bottom-left), keeping
    /// the crop inside the frame so no empty edges appear. Used for Follow-Mouse auto-zoom.
    nonisolated static func zoomed(_ image: CIImage, focus: CGPoint, zoom: CGFloat) -> CIImage {
        let ext = image.extent
        guard ext.width > 0, ext.height > 0, zoom > 1 else { return image }
        let cropW = ext.width / zoom, cropH = ext.height / zoom
        var cx = ext.minX + focus.x * ext.width
        var cy = ext.minY + focus.y * ext.height
        cx = min(max(ext.minX + cropW / 2, cx), ext.maxX - cropW / 2)
        cy = min(max(ext.minY + cropH / 2, cy), ext.maxY - cropH / 2)
        let crop = CGRect(x: cx - cropW / 2, y: cy - cropH / 2, width: cropW, height: cropH)
        return image.cropped(to: crop)
            .transformed(by: CGAffineTransform(scaleX: zoom, y: zoom))
            .transformed(by: CGAffineTransform(translationX: ext.minX - crop.minX * zoom,
                                               y: ext.minY - crop.minY * zoom))
    }

    /// Composite + export. Returns the output URL on success, nil on failure.
    @MainActor
    static func export(url: URL, options: Options, timeRange: CMTimeRange?, to out: URL) async -> URL? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await track.load(.naturalSize) else { return nil }

        let srcW = naturalSize.width, srcH = naturalSize.height
        let (renderSize, innerScale, inset) = layout(srcW: srcW, srcH: srcH,
                                                     paddingFraction: options.paddingFraction,
                                                     targetHeight: options.targetHeight)
        guard let bgCG = BeautifyRenderer.backgroundImage(options.background, size: renderSize) else { return nil }
        let background = CIImage(cgImage: bgCG)
        let renderRect = CGRect(origin: .zero, size: renderSize)

        let cursorTrack = options.cursorTrack
        let followZoom = options.followZoom
        let composition = AVMutableVideoComposition(asset: asset) { request in
            var frame = request.sourceImage
            if followZoom > 1, let cursorTrack, let p = cursorTrack.point(at: request.compositionTime.seconds) {
                frame = zoomed(frame, focus: p, zoom: followZoom)
            }
            let source = frame.clampedToExtent()
            let placed = source
                .transformed(by: CGAffineTransform(scaleX: innerScale, y: innerScale))
                .transformed(by: CGAffineTransform(translationX: inset, y: inset))
                .cropped(to: CGRect(x: inset, y: inset,
                                    width: srcW * innerScale, height: srcH * innerScale))
            let composited = placed.composited(over: background).cropped(to: renderRect)
            request.finish(with: composited, context: nil)
        }
        composition.renderSize = renderSize

        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { return nil }
        try? FileManager.default.removeItem(at: out)
        export.outputURL = out
        export.outputFileType = .mp4
        export.videoComposition = composition
        if let timeRange { export.timeRange = timeRange }

        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            export.exportAsynchronously {
                let ok = export.status == .completed
                continuation.resume(returning: ok ? out : nil)
            }
        }
    }
}
