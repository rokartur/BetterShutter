import Testing
import AppKit
import AVFoundation
import CoreGraphics
import CoreText
import ScreenCaptureKit
@testable import BetterShutter

/// Live, end-to-end verification of the capture/recording/OCR engines against the real machine.
/// The screen-dependent tests skip gracefully when Screen Recording isn't granted to the test host.
@MainActor
struct CaptureIntegrationTests {

    // MARK: OCR (no permission needed — synthetic image)

    @Test
    func ocrReadsRenderedText() async {
        let image = CapturedImage(cgImage: textImage("HELLO WORLD"), scale: 1, displayID: nil)
        let text = await TextRecognizer.recognize(image)
        #expect(text.uppercased().contains("HELLO"))
        #expect(text.uppercased().contains("WORLD"))
    }

    // MARK: Live display capture

    @Test
    func liveDisplayCaptureProducesNonBlackImage() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            print("[integration] Screen Recording NOT granted to test host — skipping live capture.")
            return
        }
        let engine = CaptureEngine()
        let images = try await engine.freezeAllDisplays()
        #expect(!images.isEmpty)
        let first = try #require(images.first)
        #expect(first.pixelSize.width > 0)
        #expect(first.pixelSize.height > 0)
        #expect(!isAllBlack(first.cgImage))
        print("[integration] Live capture OK: \(Int(first.pixelSize.width))x\(Int(first.pixelSize.height)) px")
    }

    // MARK: Live recording → playable file

    @Test
    func liveRecordingProducesPlayableFile() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            print("[integration] Screen Recording NOT granted — skipping live recording.")
            return
        }
        let engine = RecordingEngine()
        engine.captureSystemAudio = false
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bs-itest-\(UUID()).mp4")
        try await engine.start(displayID: CGMainDisplayID(), to: url)
        try await Task.sleep(for: .seconds(1.2))
        let out = await engine.stop()
        let resolved = try #require(out)
        let asset = AVURLAsset(url: resolved)
        let duration = try await asset.load(.duration)
        #expect(duration.seconds > 0.2)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        #expect(!tracks.isEmpty)
        print("[integration] Recording OK: \(String(format: "%.2f", duration.seconds))s, \(tracks.count) video track(s)")
        try? FileManager.default.removeItem(at: resolved)
    }

    // MARK: Helpers

    private func textImage(_ text: String, width: Int = 420, height: Int = 120) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = NSFont.boldSystemFont(ofSize: 48)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
        )
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: 20, y: 42)
        CTLineDraw(line, ctx)
        return ctx.makeImage()!
    }

    private func isAllBlack(_ image: CGImage) -> Bool {
        guard let rep = NSBitmapImageRep(cgImage: image) as NSBitmapImageRep? else { return false }
        let samples = [(0.1, 0.1), (0.5, 0.5), (0.9, 0.9), (0.5, 0.1), (0.1, 0.9)]
        for (fx, fy) in samples {
            let x = Int(Double(rep.pixelsWide - 1) * fx)
            let y = Int(Double(rep.pixelsHigh - 1) * fy)
            if let color = rep.colorAt(x: x, y: y),
               color.brightnessComponent > 0.02 {
                return false
            }
        }
        return true
    }
}
