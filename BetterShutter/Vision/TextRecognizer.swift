import Vision
import CoreImage

/// On-device OCR over a captured image, returning recognized text in reading order.
nonisolated enum TextRecognizer {
    /// Multi-pass: a normal pass, then a contrast-enhanced retry if nothing was found (helps with
    /// low-contrast or faint text).
    static func recognize(_ image: CapturedImage) async -> String {
        await VisionTaskRunner.run(default: "") { cancellation in
            let first = perform(image.cgImage, cancellation: cancellation)
            guard first.isEmpty, !Task.isCancelled else { return first }
            if let enhanced = contrastEnhanced(image.cgImage), !Task.isCancelled {
                return perform(enhanced, cancellation: cancellation)
            }
            return first
        }
    }

    private static func perform(_ cgImage: CGImage, cancellation: VisionRequestCancellation) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            guard try cancellation.perform(request, with: handler) else { return "" }
        } catch {
            return ""
        }
        return (request.results ?? [])
            .sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    private static func contrastEnhanced(_ cgImage: CGImage) -> CGImage? {
        let ci = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIColorControls") else { return nil }
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(1.4, forKey: kCIInputContrastKey)
        filter.setValue(0.0, forKey: kCIInputSaturationKey)
        guard let out = filter.outputImage else { return nil }
        return VisionCIContext.createCGImage(out, from: ci.extent)
    }

    /// Recognized lines with their normalized bounding boxes (Vision space: bottom-left, 0…1),
    /// which matches the editor's bottom-left image space after scaling by the image size.
    static func observations(_ image: CapturedImage) async -> [(text: String, box: CGRect)] {
        await VisionTaskRunner.run(default: []) { cancellation in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: image.cgImage, options: [:])
            do {
                guard try cancellation.perform(request, with: handler) else { return [] }
            } catch {
                return []
            }
            return (request.results ?? []).compactMap { obs -> (text: String, box: CGRect)? in
                guard let string = obs.topCandidates(1).first?.string else { return nil }
                return (text: string, box: obs.boundingBox)
            }
        }
    }
}
