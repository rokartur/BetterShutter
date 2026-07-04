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

    // MARK: Shareable content cache

    /// `SCShareableContent.excludingDesktopWindows` is the slow part of every SCK call
    /// (typically 100–300 ms). One region-capture flow hits it twice within moments (overlay
    /// open, then Space-click window capture), so keep the last fetch around briefly.
    private var cachedContent: SCShareableContent?
    private var cachedContentAt: ContinuousClock.Instant?

    private func sharedContent(maxAge: Duration = .seconds(5)) async throws -> SCShareableContent {
        if let cachedContent, let cachedContentAt, .now - cachedContentAt < maxAge {
            return cachedContent
        }
        return try await refreshedContent()
    }

    private func refreshedContent() async throws -> SCShareableContent {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        cachedContent = content
        cachedContentAt = .now
        return content
    }

    // MARK: Enumeration

    /// Snapshot of displays and capturable windows, as `Sendable` value types.
    func shareableContent() async throws -> (displays: [DisplayInfo], windows: [WindowInfo]) {
        let content = try await sharedContent()
        let ownBundleID = Bundle.main.bundleIdentifier

        let displays = content.displays.map { d in
            DisplayInfo(id: d.displayID, cgFrame: d.frame, scale: Self.scale(for: d.displayID))
        }

        // SCShareableContent.windows is NOT z-ordered, so hit-testing "front window under the
        // cursor" against it picks an arbitrary overlapping window. Pull the true front-to-back
        // order (and per-window alpha) from CGWindowList and use it to order + filter the result.
        let zOrder = Self.onScreenWindowOrder()

        let windows: [WindowInfo] = content.windows.compactMap { w -> WindowInfo? in
            guard w.isOnScreen, w.windowLayer == 0 else { return nil }
            guard w.frame.width >= 40, w.frame.height >= 40 else { return nil }
            if let app = w.owningApplication, app.bundleIdentifier == ownBundleID { return nil }
            // Drop windows that are effectively invisible (alpha ~0) so they can't grab the hover.
            if let alpha = zOrder[w.windowID]?.alpha, alpha < 0.05 { return nil }
            return WindowInfo(
                id: w.windowID,
                cgFrame: w.frame,
                title: w.title,
                appName: w.owningApplication?.applicationName
            )
        }
        // Front-to-back: known z-indices ascend (0 = frontmost); unknown windows sort to the back.
        let sorted = windows.sorted {
            (zOrder[$0.id]?.index ?? Int.max) < (zOrder[$1.id]?.index ?? Int.max)
        }
        return (displays, sorted)
    }

    /// Front-to-back on-screen window order + alpha, keyed by window id, from CGWindowList
    /// (the authoritative z-order source SCK doesn't expose).
    private static func onScreenWindowOrder() -> [CGWindowID: (index: Int, alpha: CGFloat)] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [:] }
        var map: [CGWindowID: (index: Int, alpha: CGFloat)] = [:]
        for (index, info) in list.enumerated() {
            guard let number = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            let alpha = (info[kCGWindowAlpha as String] as? CGFloat) ?? 1
            map[number] = (index, alpha)
        }
        return map
    }

    // MARK: Freeze (all displays)

    /// Capture every display at native resolution — the frozen backdrop for the overlay.
    func freezeAllDisplays() async throws -> [CapturedImage] {
        if #available(macOS 15.2, *) {
            let ids = Self.activeDisplayIDs()
            guard !ids.isEmpty else { throw CaptureError.noDisplays }
            var images: [CapturedImage] = []
            images.reserveCapacity(ids.count)
            for id in ids {
                images.append(try await Self.captureComposited(displayID: id))
            }
            return images
        }
        let content = try await sharedContent()
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
        if #available(macOS 15.2, *) {
            let ids = Self.activeDisplayIDs()
            guard let id = ids.contains(displayID) ? displayID : ids.first else {
                throw CaptureError.noDisplays
            }
            return try await Self.captureComposited(displayID: id)
        }
        let content = try await sharedContent()
        guard let display = content.displays.first(where: { $0.displayID == displayID })
            ?? content.displays.first else { throw CaptureError.noDisplays }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        return try await capture(filter: filter, displayID: display.displayID)
    }

    /// True WindowServer composite of a display — pixel-identical to what's on screen (and to
    /// the native screenshot UI), including the window-edge hairlines that filter-based SCK
    /// captures render only faintly. Also skips the SCShareableContent round-trip, so the
    /// freeze-frame appears faster.
    @available(macOS 15.2, *)
    private static func captureComposited(displayID: CGDirectDisplayID) async throws -> CapturedImage {
        let bounds = CGDisplayBounds(displayID)   // global points, top-left origin
        guard bounds.width > 0, bounds.height > 0 else { throw CaptureError.emptyCapture }
        let image = try await SCScreenshotManager.captureImage(in: bounds)
        return CapturedImage(cgImage: image, scale: CGFloat(image.width) / bounds.width,
                             displayID: displayID)
    }

    private static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    // MARK: Region (sub-rect of a display)

    /// Capture a display-local sub-rectangle (points, top-left origin) at native resolution. Used
    /// by scrolling capture to grab the same region repeatedly while the user scrolls.
    func captureRegion(displayID: CGDirectDisplayID, sourceRectPoints: CGRect) async throws -> CapturedImage {
        if #available(macOS 15.2, *) {
            guard sourceRectPoints.width > 0, sourceRectPoints.height > 0 else {
                throw CaptureError.emptyCapture
            }
            let bounds = CGDisplayBounds(displayID)
            let global = sourceRectPoints.offsetBy(dx: bounds.minX, dy: bounds.minY)
            let image = try await SCScreenshotManager.captureImage(in: global)
            return CapturedImage(cgImage: image, scale: CGFloat(image.width) / global.width,
                                 displayID: displayID)
        }
        let content = try await sharedContent()
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
