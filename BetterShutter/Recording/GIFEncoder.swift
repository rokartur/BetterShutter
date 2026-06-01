import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

/// Encodes a sequence of frames into an animated GIF.
nonisolated enum GIFEncoder {
    static func encode(frames: [CGImage], frameDelay: Double, loops: Bool = true) -> Data? {
        guard !frames.isEmpty else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.gif.identifier as CFString, frames.count, nil
        ) else { return nil }

        let fileProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loops ? 0 : 1]
        ]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)

        let frameProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: frameDelay]
        ]
        for frame in frames {
            CGImageDestinationAddImage(destination, frame, frameProperties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
