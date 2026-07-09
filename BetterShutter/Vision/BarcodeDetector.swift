import Vision

/// Detects QR codes / barcodes in a captured image and returns their decoded payloads. Payloads are
/// only ever surfaced as plain text (never auto-opened) so a malicious QR can't trigger an action.
nonisolated enum BarcodeDetector {
    static func detect(_ image: CapturedImage) async -> [String] {
        await VisionTaskRunner.run(default: []) { cancellation in
            let request = VNDetectBarcodesRequest()
            let handler = VNImageRequestHandler(cgImage: image.cgImage, options: [:])
            do {
                guard try cancellation.perform(request, with: handler) else { return [] }
            } catch {
                return []
            }
            return (request.results ?? [])
                .compactMap { $0.payloadStringValue }
                .filter { !$0.isEmpty }
        }
    }
}
