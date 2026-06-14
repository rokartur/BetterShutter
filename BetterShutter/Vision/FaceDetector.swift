import Vision

/// Detects faces in a captured image (for one-tap face redaction). Returns each face's bounding box
/// in Vision's normalized, bottom-left coordinate space.
nonisolated enum FaceDetector {
    static func detect(_ image: CapturedImage) async -> [CGRect] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[CGRect], Never>) in
            let request = VNDetectFaceRectanglesRequest { request, _ in
                let boxes = (request.results as? [VNFaceObservation] ?? []).map { $0.boundingBox }
                continuation.resume(returning: boxes)
            }
            let handler = VNImageRequestHandler(cgImage: image.cgImage, options: [:])
            do { try handler.perform([request]) } catch { continuation.resume(returning: []) }
        }
    }
}
