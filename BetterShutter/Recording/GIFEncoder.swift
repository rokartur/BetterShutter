import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

/// Encodes a sequence of frames into an animated GIF.
nonisolated enum GIFEncoder {
    /// Encode PNG-compressed frames (as buffered by `RecordingEngine` during a GIF recording)
    /// straight to a file. Frames are decoded one at a time inside an autorelease pool, so peak
    /// memory stays at ~one decoded frame instead of the whole clip's raw bitmaps.
    static func encode(frameData: [Data], frameDelay: Double, to url: URL, loops: Bool = true) -> Bool {
        guard !frameData.isEmpty,
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL, UTType.gif.identifier as CFString, frameData.count, nil
              ) else { return false }

        let fileProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loops ? 0 : 1]
        ]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)

        let frameProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: frameDelay]
        ]
        var added = 0
        for data in frameData {
            autoreleasepool {
                if let source = CGImageSourceCreateWithData(data as CFData, nil),
                   let frame = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                    CGImageDestinationAddImage(destination, frame, frameProperties as CFDictionary)
                    added += 1
                }
            }
        }
        // The destination was created for exactly `frameData.count` images; a decode failure
        // would make finalize fail anyway, so bail explicitly.
        guard added == frameData.count else { return false }
        return CGImageDestinationFinalize(destination)
    }
}
