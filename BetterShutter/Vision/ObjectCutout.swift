import Vision
import CoreImage

/// Lifts the foreground subject out of a captured image — Snapzy-style "object cutout". Uses
/// Vision's foreground-instance mask, returns a transparent-background bitmap auto-cropped to the
/// subject's extent, or `nil` if no salient subject is found.
nonisolated enum ObjectCutout {
    static func cutout(_ image: CapturedImage) async -> CapturedImage? {
        await Task.detached(priority: .userInitiated) { generate(from: image) }.value
    }

    private static func generate(from image: CapturedImage) -> CapturedImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image.cgImage, options: [:])
        do {
            try handler.perform([request])
            guard let result = request.results?.first, !result.allInstances.isEmpty else { return nil }
            let buffer = try result.generateMaskedImage(
                ofInstances: result.allInstances,
                from: handler,
                croppedToInstancesExtent: true
            )
            let ci = CIImage(cvPixelBuffer: buffer)
            let context = CIContext()
            guard let cg = context.createCGImage(ci, from: ci.extent) else { return nil }
            return CapturedImage(cgImage: cg, scale: image.scale, displayID: image.displayID)
        } catch {
            return nil
        }
    }
}
