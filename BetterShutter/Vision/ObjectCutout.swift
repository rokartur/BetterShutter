import Vision
import CoreImage

/// Lifts the foreground subject out of a captured image — Snapzy-style "object cutout". Uses
/// Vision's foreground-instance mask, returns a transparent-background bitmap auto-cropped to the
/// subject's extent, or `nil` if no salient subject is found.
nonisolated enum ObjectCutout {
    static func cutout(_ image: CapturedImage) async -> CapturedImage? {
        await VisionTaskRunner.run(default: nil) { cancellation in
            generate(from: image, cancellation: cancellation)
        }
    }

    private static func generate(
        from image: CapturedImage,
        cancellation: VisionRequestCancellation
    ) -> CapturedImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image.cgImage, options: [:])
        do {
            guard try cancellation.perform(request, with: handler) else { return nil }
            guard let result = request.results?.first, !result.allInstances.isEmpty else { return nil }
            guard !Task.isCancelled else { return nil }
            let buffer = try result.generateMaskedImage(
                ofInstances: result.allInstances,
                from: handler,
                croppedToInstancesExtent: true
            )
            guard !Task.isCancelled else { return nil }
            let ci = CIImage(cvPixelBuffer: buffer)
            guard let cg = VisionCIContext.createCGImage(ci, from: ci.extent) else { return nil }
            return CapturedImage(cgImage: cg, scale: image.scale, displayID: image.displayID)
        } catch {
            return nil
        }
    }
}
