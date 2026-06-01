import Vision

/// On-device OCR over a captured image, returning recognized text in reading order.
nonisolated enum TextRecognizer {
    static func recognize(_ image: CapturedImage) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let text = observations
                    .sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                continuation.resume(returning: text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: image.cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: "")
            }
        }
    }

    /// Recognized lines with their normalized bounding boxes (Vision space: bottom-left, 0…1),
    /// which matches the editor's bottom-left image space after scaling by the image size.
    static func observations(_ image: CapturedImage) async -> [(text: String, box: CGRect)] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[(text: String, box: CGRect)], Never>) in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let result = observations.compactMap { obs -> (text: String, box: CGRect)? in
                    guard let string = obs.topCandidates(1).first?.string else { return nil }
                    return (text: string, box: obs.boundingBox)
                }
                continuation.resume(returning: result)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: image.cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: [])
            }
        }
    }
}
