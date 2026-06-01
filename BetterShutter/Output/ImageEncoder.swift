import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The single CGImage → encoded `Data` path, shared by save-to-disk, drag-out, and copy.
nonisolated enum ImageEncoder {
    static func encode(_ cgImage: CGImage, as format: ImageFileFormat, quality: Double = 0.9) -> Data? {
        let type: UTType = (format == .png) ? .png : .jpeg
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, type.identifier as CFString, 1, nil
        ) else { return nil }

        var properties: [CFString: Any] = [:]
        if format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
