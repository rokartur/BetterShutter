import Foundation

/// Parses `bettershutter://` automation URLs into commands. Pure and unit-tested; `AppDelegate`
/// dispatches each command via `application(_:open:)`.
///
/// NOTE: routing only works once the `bettershutter` URL scheme is registered for the app target
/// (Xcode ▸ target ▸ Info ▸ URL Types, or a CFBundleURLTypes entry). The handler is ready; that
/// registration is the one remaining manual config step (left out of code to avoid converting the
/// auto-generated Info.plist and risking the LSUIElement / mic-usage keys).
nonisolated enum URLCommand: Equatable {
    case captureRegion, captureWindow, captureFullScreen, captureText, captureScrolling, captureCutout
    case record, recordGIF, recordRegion, recordWindow
    case capturePreviousArea
    case openBrowser, openSettings, pinLast
    case unknown(String)

    static func parse(_ url: URL) -> URLCommand? {
        guard url.scheme?.lowercased() == "bettershutter" else { return nil }
        // Accept both bettershutter://capture-region and bettershutter:capture-region forms.
        let raw = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch raw.lowercased() {
        case "capture-region", "region":        return .captureRegion
        case "capture-window", "window":         return .captureWindow
        case "capture-fullscreen", "fullscreen": return .captureFullScreen
        case "capture-text", "ocr", "text":      return .captureText
        case "scrolling-capture", "scrolling":   return .captureScrolling
        case "capture-object", "cutout":         return .captureCutout
        case "record":                           return .record
        case "record-gif", "gif":                return .recordGIF
        case "record-region":                    return .recordRegion
        case "record-window":                    return .recordWindow
        case "capture-previous-area", "previous": return .capturePreviousArea
        case "browse", "browser":                return .openBrowser
        case "settings":                         return .openSettings
        case "pin-last", "pin":                  return .pinLast
        case "":                                 return nil
        default:                                 return .unknown(raw)
        }
    }
}
