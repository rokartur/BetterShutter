import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The single CGImage → encoded `Data` path, shared by save-to-disk, drag-out, and copy.
nonisolated enum ImageEncoder {
    static func encode(_ cgImage: CGImage, as format: ImageFileFormat, quality: Double = 0.9) -> Data? {
        let type: UTType
        switch format {
        case .png: type = .png
        case .jpeg: type = .jpeg
        case .heic: type = .heic
        case .webp: type = .webP
        }
        let data = NSMutableData()
        // WebP encoding requires ImageIO to advertise the writer; if the OS can't encode it,
        // destination creation fails and we return nil (callers fall back).
        guard let destination = CGImageDestinationCreateWithData(
            data, type.identifier as CFString, 1, nil
        ) else { return nil }

        var properties: [CFString: Any] = [:]
        if format.isLossy {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
