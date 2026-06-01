import AppKit
import AVFoundation
import CoreGraphics

/// Hidden diagnostic: when launched with `BS_SELFTEST=1`, exercises the real capture and recording
/// engines, writes a result summary to ~/bs-selftest-result.txt and stderr, then quits. Lets the
/// capture/recording pipelines be verified live (in the app's own TCC identity) without UI gestures.
@MainActor
enum SelfTest {
    static func runIfRequested() -> Bool {
        guard ProcessInfo.processInfo.environment["BS_SELFTEST"] == "1" else { return false }
        Task { await run() }
        return true
    }

    private static func run() async {
        var lines: [String] = []
        let granted = CGPreflightScreenCaptureAccess()
        lines.append("screenRecordingGranted=\(granted)")

        if granted {
            do {
                let engine = CaptureEngine()
                let images = try await engine.freezeAllDisplays()
                if let first = images.first {
                    let png = ImageEncoder.encode(first.cgImage, as: .png)
                    if let png {
                        try? png.write(to: URL(fileURLWithPath: ("~/bs-selftest-capture.png" as NSString).expandingTildeInPath))
                    }
                    let stats = brightnessStats(first.cgImage)
                    lines.append("capture=OK size=\(Int(first.pixelSize.width))x\(Int(first.pixelSize.height)) pngBytes=\(png?.count ?? 0) nonBlackCells=\(stats.nonBlack)/1024 maxLuma=\(String(format: "%.3f", stats.maxLuma))")
                } else {
                    lines.append("capture=NO_IMAGES")
                }
            } catch {
                lines.append("capture=ERR \(error)")
            }

            let recorder = RecordingEngine()
            recorder.captureSystemAudio = false
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("bs-selftest.mp4")
            do {
                try await recorder.start(displayID: CGMainDisplayID(), to: url)
                try? await Task.sleep(for: .seconds(1.0))
                if let out = await recorder.stop() {
                    let asset = AVURLAsset(url: out)
                    let duration = (try? await asset.load(.duration))?.seconds ?? 0
                    let tracks = (try? await asset.loadTracks(withMediaType: .video))?.count ?? 0
                    lines.append("recording=OK dur=\(String(format: "%.2f", duration)) videoTracks=\(tracks)")
                    try? FileManager.default.removeItem(at: out)
                } else {
                    lines.append("recording=NIL")
                }
            } catch {
                lines.append("recording=ERR \(error)")
            }
        }

        let text = lines.joined(separator: "\n") + "\n"
        let outURL = URL(fileURLWithPath: ("~/bs-selftest-result.txt" as NSString).expandingTildeInPath)
        try? text.write(to: outURL, atomically: true, encoding: .utf8)
        FileHandle.standardError.write(Data(("SELFTEST_BEGIN\n" + text + "SELFTEST_END\n").utf8))
        NSApp.terminate(nil)
    }

    /// Down-samples into a known sRGB 32x32 RGBA buffer and reads bytes directly (reliable, unlike
    /// NSBitmapImageRep.colorAt on SCK's BGRA output).
    private static func brightnessStats(_ image: CGImage) -> (nonBlack: Int, maxLuma: Double) {
        let w = 32, h = 32
        var data = [UInt8](repeating: 0, count: w * h * 4)
        var nonBlack = 0
        var maxLuma = 0.0
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                    data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            let p = raw.bindMemory(to: UInt8.self)
            for i in stride(from: 0, to: w * h * 4, by: 4) {
                let r = Double(p[i]) / 255, g = Double(p[i + 1]) / 255, b = Double(p[i + 2]) / 255
                let luma = 0.299 * r + 0.587 * g + 0.114 * b
                if luma > 0.05 { nonBlack += 1 }
                maxLuma = max(maxLuma, luma)
            }
        }
        return (nonBlack, maxLuma)
    }
}
