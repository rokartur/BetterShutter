import AVFoundation
import CoreGraphics
import ImageIO

/// First-frame extraction for the recording quick-access card: AVFoundation for movie files,
/// ImageIO for GIFs (AVAssetImageGenerator can't read GIF).
nonisolated enum VideoThumbnailer {
    @concurrent
    static func firstFrame(of url: URL) async -> CGImage? {
        if url.pathExtension.lowercased() == "gif" {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1600, height: 1600)
        return try? await generator.image(at: .zero).image
    }
}
