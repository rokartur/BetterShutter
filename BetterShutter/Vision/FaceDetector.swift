import Vision

/// Detects faces in a captured image (for one-tap face redaction). Returns each face's bounding box
/// in Vision's normalized, bottom-left coordinate space.
nonisolated enum FaceDetector {
    static func detect(_ image: CapturedImage) async -> [CGRect] {
        await VisionTaskRunner.run(default: []) { cancellation in
            let request = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: image.cgImage, options: [:])
            do {
                guard try cancellation.perform(request, with: handler) else { return [] }
            } catch {
                return []
            }
            return (request.results ?? []).map(\.boundingBox)
        }
    }
}
