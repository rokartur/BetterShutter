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
        // WebP encoding requires ImageIO to advertise a writer for it; if the OS can't encode the
        // requested type, destination creation fails and this returns nil. Callers must surface that
        // (e.g. a "Save failed" toast) — there is no automatic format fallback.
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
