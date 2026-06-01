import CoreGraphics
import ScreenCaptureKit

nonisolated enum CaptureError: Error, LocalizedError {
    case noDisplays
    case windowNotFound
    case emptyCapture

    var errorDescription: String? {
        switch self {
        case .noDisplays: return "No displays are available to capture."
        case .windowNotFound: return "The selected window is no longer available."
        case .emptyCapture: return "The capture produced an empty image."
        }
    }
}

/// The only type that touches ScreenCaptureKit. Runs off the main actor so SCK calls and
/// bitmap work never jank the UI. Hands back only `Sendable` value types.
actor CaptureEngine {

    // MARK: Enumeration

    /// Snapshot of displays and capturable windows, as `Sendable` value types.
    func shareableContent() async throws -> (displays: [DisplayInfo], windows: [WindowInfo]) {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        let ownBundleID = Bundle.main.bundleIdentifier

        let displays = content.displays.map { d in
            DisplayInfo(id: d.displayID, cgFrame: d.frame, scale: Self.scale(for: d.displayID))
        }

        let windows: [WindowInfo] = content.windows.compactMap { w in
            guard w.isOnScreen, w.windowLayer == 0 else { return nil }
            guard w.frame.width >= 40, w.frame.height >= 40 else { return nil }
            if let app = w.owningApplication, app.bundleIdentifier == ownBundleID { return nil }
            return WindowInfo(
                id: w.windowID,
                cgFrame: w.frame,
                title: w.title,
                appName: w.owningApplication?.applicationName
            )
        }
        return (displays, windows)
    }

    // MARK: Freeze (all displays)

    /// Capture every display at native resolution — the frozen backdrop for the overlay.
    func freezeAllDisplays() async throws -> [CapturedImage] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard !content.displays.isEmpty else { throw CaptureError.noDisplays }
        var images: [CapturedImage] = []
        images.reserveCapacity(content.displays.count)
        for display in content.displays {
            let filter = SCContentFilter(display: display, excludingWindows: [])
            images.append(try await capture(filter: filter, displayID: display.displayID))
        }
        return images
    }

    /// Capture a single display under the given id (used by full-screen mode without an overlay).
    func captureDisplay(_ displayID: CGDirectDisplayID) async throws -> CapturedImage {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard let display = content.displays.first(where: { $0.displayID == displayID })
            ?? content.displays.first else { throw CaptureError.noDisplays }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        return try await capture(filter: filter, displayID: display.displayID)
    }

    // MARK: Region (sub-rect of a display)

    /// Capture a display-local sub-rectangle (points, top-left origin) at native resolution. Used
    /// by scrolling capture to grab the same region repeatedly while the user scrolls.
    func captureRegion(displayID: CGDirectDisplayID, sourceRectPoints: CGRect) async throws -> CapturedImage {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard let display = content.displays.first(where: { $0.displayID == displayID })
            ?? content.displays.first else { throw CaptureError.noDisplays }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        let widthPx = Int((sourceRectPoints.width * scale).rounded())
        let heightPx = Int((sourceRectPoints.height * scale).rounded())
        guard widthPx > 0, heightPx > 0 else { throw CaptureError.emptyCapture }

        let config = SCStreamConfiguration()
        config.sourceRect = sourceRectPoints
        config.width = widthPx
        config.height = heightPx
        config.captureResolution = .best
        config.scalesToFit = false
        config.showsCursor = false
        config.colorSpaceName = CGColorSpace.sRGB

        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config
        )
        return CapturedImage(cgImage: cgImage, scale: scale, displayID: displayID)
    }

    // MARK: Window

    func captureWindow(_ windowID: CGWindowID) async throws -> CapturedImage {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotFound
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        return try await capture(filter: filter, displayID: nil, includeShadow: Preferences.includeWindowShadow)
    }

    // MARK: Core

    /// Size the configuration in PIXELS using the filter's authoritative point/pixel scale, then
    /// take a one-shot screenshot.
    private func capture(filter: SCContentFilter, displayID: CGDirectDisplayID?,
                         includeShadow: Bool = false) async throws -> CapturedImage {
        let scale = CGFloat(filter.pointPixelScale)
        let widthPx = Int((filter.contentRect.width * scale).rounded())
        let heightPx = Int((filter.contentRect.height * scale).rounded())
        guard widthPx > 0, heightPx > 0 else { throw CaptureError.emptyCapture }

        let config = SCStreamConfiguration()
        config.width = widthPx
        config.height = heightPx
        config.captureResolution = .best
        config.scalesToFit = false
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = !includeShadow
        config.colorSpaceName = CGColorSpace.sRGB

        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config
        )
        return CapturedImage(cgImage: cgImage, scale: scale, displayID: displayID)
    }

    // MARK: Scale

    nonisolated static func scale(for displayID: CGDirectDisplayID) -> CGFloat {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return 1 }
        let widthPoints = CGDisplayBounds(displayID).width
        guard widthPoints > 0 else { return 1 }
        return CGFloat(mode.pixelWidth) / widthPoints
    }
}
