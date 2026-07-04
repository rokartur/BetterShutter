# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

BetterShutter — native macOS (AppKit) menu-bar screenshot & screen-recording app. macOS 14+, menu-bar agent (no Dock icon), not sandboxed (in-place updater replaces the bundle). Swift 6 with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — everything is MainActor by default; cross-actor value/utility types must be explicitly `nonisolated`.

## Commands

Build:

```bash
xcodebuild -project BetterShutter.xcodeproj -scheme "BetterShutter Debug" \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO -destination 'platform=macOS'
```

Run all tests:

```bash
xcodebuild -project BetterShutter.xcodeproj -scheme "BetterShutter Debug" \
  -configuration Debug test CODE_SIGNING_ALLOWED=NO -destination 'platform=macOS'
```

Run a single test suite or test (Swift Testing, not XCTest):

```bash
xcodebuild ... test -only-testing:BetterShutterTests/CoordinateConverterTests
xcodebuild ... test -only-testing:BetterShutterTests/CoordinateConverterTests/cropRectOnPrimaryRetina
```

Schemes: "BetterShutter Debug" and "BetterShutter Release". SPM dependencies (BetterSettings, BetterUpdater, BetterShortcuts — all github.com/rokartur) resolve automatically. `buildServer.json` is present for xcode-build-server / SourceKit-LSP.

Source lives in `BetterShutter/` as Xcode **synced folders** — new files are picked up automatically, no project-file edits needed.

## Architecture

Capture pipeline (the core flow):

- `Capture/CaptureEngine` (`actor`) — the **only** ScreenCaptureKit touch-point. Returns `Sendable` value types: `CapturedImage`, `DisplayInfo`, `WindowInfo`.
- `Capture/CoordinateConverter` — the single source of points↔pixels and AppKit↔CoreGraphics y-flip math (Retina + multi-display; unit-tested). Do not duplicate coordinate math elsewhere.
- `Capture/CaptureCoordinator` (`@MainActor`) — orchestrates permission → freeze-frame → overlay → output, and owns the editor/beautify/preview controllers.
- `Overlay/` — freeze-frame selection UI (magnifier loupe, crosshair, window highlighting, edge snapping), all sampled from a frozen screenshot.

Rendering: the editor (`Editor/`) and beautify (`Beautify/`) draw in **image-pixel, bottom-left** space via CoreGraphics/CoreText, so the on-screen canvas and the full-resolution export share one code path.

Recording: `Recording/RecordingEngine` runs off-main on a serial writer queue, driving `SCStream` → `AVAssetWriter` (H.264 MP4) or a frame collector (GIF).

Other seams: `Output/` (encode/save/pasteboard/filename templating), `Vision/` (on-device OCR, barcode, face, cutout), `Cloud/` (uploads incl. SigV4), `HotKeys/` (global shortcuts via BetterShortcuts, shipped unassigned), `History/` (last 10 captures), `Preview/` (post-capture float card), `Automation/` (App Intents + URL scheme).

## Testing notes

Tests use the Swift Testing framework (`@Test`, `#expect`). `BetterShutterTests.swift` covers coordinate math, filename templating, annotation/beautify/GIF flatten+encode, crop, and history. `CaptureIntegrationTests.swift` exercises the real engines: OCR always runs; live display-capture and recording tests run only when the test host has Screen Recording permission and skip otherwise.

## Permissions quirk

Capture/recording need Screen Recording access; after granting, the app must be **relaunched** (TCC quirk). Keep this in mind when a live test or manual run appears to fail with permission granted.
