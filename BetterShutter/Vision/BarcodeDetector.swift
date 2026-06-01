import Vision

/// Detects QR codes / barcodes in a captured image and returns their decoded payloads. Payloads are
/// only ever surfaced as plain text (never auto-opened) so a malicious QR can't trigger an action.
nonisolated enum BarcodeDetector {
    static func detect(_ image: CapturedImage) async -> [String] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[String], Never>) in
            let request = VNDetectBarcodesRequest { request, _ in
                let payloads = (request.results as? [VNBarcodeObservation] ?? [])
                    .compactMap { $0.payloadStringValue }
                    .filter { !$0.isEmpty }
                continuation.resume(returning: payloads)
            }
            let handler = VNImageRequestHandler(cgImage: image.cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: [])
            }
        }
    }
}
