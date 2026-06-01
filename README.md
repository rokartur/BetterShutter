# BetterShutter

A native macOS (AppKit) menu-bar screenshot & screen-recording app. Fast capture with a
freeze-frame overlay, an annotation editor, Xnapper/Snapzy-style beautify, screen/GIF recording,
and on-device text capture (OCR).

Requires macOS 14+. Menu-bar agent (no Dock icon). Distributed outside the App Store
(Developer ID + notarization) — not sandboxed, because the in-place updater replaces the bundle.

## Features

- **Capture** — region, window, full-screen, and **text (OCR)**. A freeze-frame overlay gives a
  pixel-accurate magnifier loupe with a hex/RGB readout, live W×H-in-pixels, crosshair, window
  highlighting, and edge snapping — all sampled from a frozen screenshot, so it feels instant.
- **Float preview** — a quick-access card after each capture: Copy, Show in Finder, Edit,
  Beautify, drag-out as a real PNG, auto-dismiss. Right-click for more.
- **History** — the last 10 captures live in the menu's **Recent** submenu; click to reopen.
- **Annotation editor** — arrow, rectangle, ellipse, line, text, highlighter, pixelate, numbered
  step badges, and **crop**. Select / move / delete, color + stroke width.
- **Beautify** — drop a screenshot onto gradient/solid backgrounds with padding, rounded corners,
  shadow, and an optional macOS **window-chrome frame** (light/dark, traffic lights).
- **Recording** — full-screen or **region** to H.264 MP4 with optional system audio, or an
  animated **GIF**. A floating control bar shows elapsed time and Stop.
- **Global hotkeys** — every action is bindable in Settings ▸ Shortcuts (shipped **unassigned**
  so they never clash with Apple's ⌘⇧3/4/5). Menu items mirror the assigned combo.

## Build

```bash
xcodebuild -project BetterShutter.xcodeproj -scheme "BetterShutter Debug" \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO -destination 'platform=macOS'
```

Dependencies (SPM, resolved automatically): BetterSettings, BetterUpdater, BetterShortcuts.

## Permissions

Capture and recording need **Screen Recording** access. On first capture macOS prompts; after
granting, **relaunch** the app (a TCC quirk). Text capture also uses Vision (on-device, no
network). The mic-usage string is present for a future mic-in-recording feature.

## Verify

```bash
xcodebuild -project BetterShutter.xcodeproj -scheme "BetterShutter Debug" \
  -configuration Debug test CODE_SIGNING_ALLOWED=NO -destination 'platform=macOS'
```

Unit tests cover the coordinate math (Retina + multi-display y-flip), filename templating,
annotation/beautify/GIF flatten+encode, crop, and history. `CaptureIntegrationTests` additionally
exercises the **real** engines: OCR runs always; the live display-capture and recording tests
run automatically once the test host has Screen Recording permission (and skip otherwise).

## Architecture

All capture-feature code lives under `BetterShutter/` (Xcode synced folders — new files need no
project edits). Key seams:

- `Capture/CaptureEngine` (`actor`) is the only ScreenCaptureKit touch-point; it returns the
  `Sendable` `CapturedImage`/`DisplayInfo`/`WindowInfo` value types.
- `Capture/CoordinateConverter` is the single source of points↔pixels and AppKit↔CoreGraphics
  y-flip math (unit-tested).
- `Capture/CaptureCoordinator` (`@MainActor`) orchestrates permission → freeze → overlay → output
  and owns the editor/beautify/preview controllers.
- Editor and beautify draw in **image-pixel, bottom-left** space via CoreGraphics/CoreText, so the
  on-screen canvas and the full-resolution export share one code path.
- `Recording/RecordingEngine` (off-main, serial writer queue) drives `SCStream` → `AVAssetWriter`
  (MP4) or a frame collector (GIF).

The project targets Swift 6 with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; cross-actor value
and utility types are explicitly `nonisolated`.
