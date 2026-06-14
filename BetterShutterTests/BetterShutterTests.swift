import Testing
import AppKit
import CoreGraphics
import CoreImage
import BetterShortcuts
@testable import BetterShutter

struct BetterShutterTests {
    @Test @MainActor
    func settingsConfigurationHasTabs() {
        let configuration = makeSettingsConfiguration()
        #expect(configuration.tabs.isEmpty == false)
        #expect(configuration.tabs.contains { $0.id == "general" })
        #expect(configuration.tabs.contains { $0.id == "shortcuts" })
        #expect(configuration.tabs.contains { $0.id == "capture" })
        #expect(configuration.tabs.contains { $0.id == "editor" })
        #expect(configuration.tabs.contains { $0.id == "beautify" })
        #expect(configuration.tabs.contains { $0.id == "cloud" })
        #expect(configuration.tabs.contains { $0.id == "advanced" })
    }
}

struct CoordinateConverterTests {
    @Test
    func cropRectOnPrimaryRetina() {
        // Primary display: 1000×800 pt @2x → 2000×1600 px.
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let pixelSize = CGSize(width: 2000, height: 1600)
        // Selection in AppKit (bottom-left) coords: top edge at y = 250.
        let selection = CGRect(x: 100, y: 100, width: 200, height: 150)
        let crop = CoordinateConverter.pixelCropRect(globalRect: selection, displayFrame: frame, pixelSize: pixelSize)
        #expect(crop == CGRect(x: 200, y: 1100, width: 400, height: 300))
    }

    @Test
    func cropRectOnNegativeOriginSecondary() {
        // Secondary display to the left: origin x = -1440, 1×.
        let frame = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let pixelSize = CGSize(width: 1440, height: 900)
        let selection = CGRect(x: -1400, y: 100, width: 200, height: 100)
        let crop = CoordinateConverter.pixelCropRect(globalRect: selection, displayFrame: frame, pixelSize: pixelSize)
        #expect(crop == CGRect(x: 40, y: 700, width: 200, height: 100))
    }

    @Test
    func pixelPointFlipsY() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let pixelSize = CGSize(width: 2000, height: 1600)
        let p = CoordinateConverter.pixelPoint(globalPoint: CGPoint(x: 100, y: 700), displayFrame: frame, pixelSize: pixelSize)
        #expect(p == CGPoint(x: 200, y: 200))
    }

    @Test
    func cgAppKitRectRoundTrip() {
        let primaryHeight: CGFloat = 800
        let cg = CGRect(x: 100, y: 50, width: 200, height: 100)
        let ak = CoordinateConverter.appKitRect(fromCGGlobalRect: cg, primaryHeight: primaryHeight)
        #expect(ak == CGRect(x: 100, y: 650, width: 200, height: 100))
        let back = CoordinateConverter.cgGlobalRect(fromAppKitRect: ak, primaryHeight: primaryHeight)
        #expect(back == cg)
    }

    @Test
    func cropRectClampsToBitmap() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let pixelSize = CGSize(width: 100, height: 100)
        // Selection partly off the right/top edge.
        let selection = CGRect(x: 80, y: 80, width: 40, height: 40)
        let crop = CoordinateConverter.pixelCropRect(globalRect: selection, displayFrame: frame, pixelSize: pixelSize)
        #expect(crop.maxX <= pixelSize.width)
        #expect(crop.maxY <= pixelSize.height)
        #expect(crop.minX >= 0 && crop.minY >= 0)
    }
}

struct FilenameTemplateTests {
    @Test
    func rendersModeAndCounter() {
        let name = FilenameTemplate.render("{mode}-{n}", mode: .region, format: .png, counter: 7)
        #expect(name == "Region-7.png")
    }

    @Test
    func sanitizesIllegalCharacters() {
        let name = FilenameTemplate.render("a/b:c", mode: .window, format: .jpeg, counter: 1)
        #expect(!name.contains("/"))
        #expect(!name.contains(":"))
        #expect(name.hasSuffix(".jpg"))
    }

    @Test
    func replacesAllTokens() {
        let name = FilenameTemplate.render("Shot {date} {time} {datetime}", mode: .fullDisplay, format: .png, counter: 3)
        #expect(!name.contains("{"))
        #expect(name.hasSuffix(".png"))
    }

    @Test
    func emptyTemplateFallsBack() {
        let name = FilenameTemplate.render("", mode: .region, format: .png, counter: 1)
        #expect(!name.isEmpty)
        #expect(name.hasSuffix(".png"))
    }
}

@MainActor
func makeSolidTestImage(width: Int, height: Int) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(NSColor.blue.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

@MainActor
struct AnnotationRendererTests {
    private func solidImage(width: Int, height: Int) -> CGImage {
        makeSolidTestImage(width: width, height: height)
    }

    @Test
    func flattenPreservesSizeWithNoElements() {
        let base = solidImage(width: 20, height: 10)
        let out = AnnotationRenderer.flatten(base: base, elements: [], ciContext: CIContext())
        #expect(out?.width == 20)
        #expect(out?.height == 10)
    }

    @Test
    func flattenWithElementsKeepsSize() {
        let base = solidImage(width: 40, height: 30)
        let style = AnnotationStyle.makeDefault(imageWidth: 40)
        let rect = RectangleElement(start: CGPoint(x: 5, y: 5), style: style)
        rect.updateDrag(to: CGPoint(x: 25, y: 22))
        let arrow = ArrowElement(start: CGPoint(x: 2, y: 2), style: style)
        arrow.updateDrag(to: CGPoint(x: 30, y: 25))
        let out = AnnotationRenderer.flatten(base: base, elements: [rect, arrow], ciContext: CIContext())
        #expect(out?.width == 40)
        #expect(out?.height == 30)
    }

    @Test
    func redactionAndSpotlightToolsFlattenAtSameSize() {
        let base = makeSolidTestImage(width: 60, height: 50)
        let style = AnnotationStyle.makeDefault(imageWidth: 60)
        let blur = BlurElement(start: CGPoint(x: 5, y: 5), style: style)
        blur.updateDrag(to: CGPoint(x: 30, y: 30))
        let black = BlackoutElement(start: CGPoint(x: 10, y: 10), style: style)
        black.updateDrag(to: CGPoint(x: 40, y: 35))
        let spot = SpotlightElement(start: CGPoint(x: 15, y: 15), style: style)
        spot.updateDrag(to: CGPoint(x: 45, y: 40))
        let out = AnnotationRenderer.flatten(base: base, elements: [blur, black, spot], ciContext: CIContext())
        #expect(out?.width == 60)
        #expect(out?.height == 50)
        // The new tools are drag-created and deep-copy through the shared clone(), like other shapes.
        #expect(blur.clone() is BlurElement)
        #expect(spot.clone() is SpotlightElement)
    }

    @Test
    func cropRectShrinksOutput() {
        let base = makeSolidTestImage(width: 100, height: 80)
        let out = AnnotationRenderer.flatten(
            base: base, elements: [], ciContext: CIContext(),
            cropRect: CGRect(x: 10, y: 10, width: 40, height: 30)
        )
        #expect(out?.width == 40)
        #expect(out?.height == 30)
    }
}

@MainActor
struct BeautifyRendererTests {
    @Test
    func renderAddsPaddingAroundImage() {
        let base = makeSolidTestImage(width: 100, height: 80)
        let style = BeautifyStyle.makeDefault()
        let out = BeautifyRenderer.render(base: base, style: style)
        #expect(out != nil)
        #expect((out?.width ?? 0) > 100)
        #expect((out?.height ?? 0) > 80)
    }

    @Test
    func squareTargetAspectProducesSquareOutput() {
        let base = makeSolidTestImage(width: 200, height: 100)
        var style = BeautifyStyle.makeDefault()
        style.targetAspect = 1
        let out = BeautifyRenderer.render(base: base, style: style)
        #expect(out != nil)
        #expect(abs((out?.width ?? 0) - (out?.height ?? 0)) <= 1)
    }

    @Test
    func zeroPaddingMatchesImageSize() {
        let base = makeSolidTestImage(width: 64, height: 64)
        var style = BeautifyStyle.makeDefault()
        style.paddingFraction = 0
        let out = BeautifyRenderer.render(base: base, style: style)
        #expect(out?.width == 64)
        #expect(out?.height == 64)
    }
}

@MainActor
struct ShortcutPolicyTests {
    /// Guards that BetterShutter links BetterShortcuts ≥ 0.2.0, whose default recorder policy
    /// allows ⌘⇧-style shortcuts (the whole point of the dependency bump).
    @Test
    func defaultRecorderPolicyAllowsShift() {
        #expect(BetterShortcuts.recorderPolicy.allowsShift)
    }
}

@MainActor
struct CaptureHistoryTests {
    private func image() -> CapturedImage {
        CapturedImage(cgImage: makeSolidTestImage(width: 4, height: 4), scale: 1, displayID: nil)
    }

    @Test
    func ringBufferCapsAtLimit() {
        let history = CaptureHistory()
        for _ in 0..<(history.limit + 5) { history.add(image(), mode: .region) }
        #expect(history.items.count == history.limit)
    }

    @Test
    func newestEntryIsFirst() {
        let history = CaptureHistory()
        history.add(image(), mode: .region, date: Date(timeIntervalSince1970: 1))
        history.add(image(), mode: .window, date: Date(timeIntervalSince1970: 2))
        #expect(history.items.first?.mode == .window)
    }

    @Test
    func clearEmptiesHistory() {
        let history = CaptureHistory()
        history.add(image(), mode: .fullDisplay)
        history.clear()
        #expect(history.items.isEmpty)
    }
}

@MainActor
struct PixelSamplerTests {
    private func context(width: Int, height: Int) -> CGContext {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                         bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    @Test
    func samplesKnownColor() {
        let ctx = context(width: 4, height: 4)
        ctx.setFillColor(NSColor(srgbRed: 1, green: 128.0 / 255, blue: 0, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let rgb = PixelSampler.rgb(in: ctx.makeImage()!, x: 1, y: 1)
        #expect(rgb != nil)
        #expect(abs((rgb?.r ?? 0) - 255) <= 2)
        #expect(abs((rgb?.g ?? 0) - 128) <= 2)
        #expect(abs((rgb?.b ?? 0) - 0) <= 2)
    }

    @Test
    func samplesCorrectPixelUsingTopLeftOrigin() {
        // Paint the TOP-LEFT pixel red (bottom-left context → fill the top row), rest black.
        let ctx = context(width: 2, height: 2)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        ctx.setFillColor(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 1, width: 1, height: 1))
        let image = ctx.makeImage()!
        #expect((PixelSampler.rgb(in: image, x: 0, y: 0)?.r ?? 0) > 200) // top-left = red
        #expect((PixelSampler.rgb(in: image, x: 0, y: 1)?.r ?? 255) < 50) // below = black
    }

    @Test
    func outOfBoundsReturnsNil() {
        let image = makeSolidTestImage(width: 4, height: 4)
        #expect(PixelSampler.rgb(in: image, x: 10, y: 10) == nil)
        #expect(PixelSampler.rgb(in: image, x: -1, y: 0) == nil)
    }
}

@MainActor
struct ScrollStitcherTests {
    /// Build a W×H image whose rows are a deterministic gradient keyed by a vertical offset, so two
    /// images that differ only by a known scroll have predictable, matchable row signatures.
    /// High-entropy per-row hash so each visual row has a distinctive, non-periodic color — the way
    /// real screen content does. This makes the true scroll offset the unique global minimum.
    private func hashByte(_ n: Int, shift: UInt32) -> CGFloat {
        let h = UInt32(truncatingIfNeeded: n &* 2654435761)
        return CGFloat((h >> shift) & 0xFF) / 255
    }

    private func gradient(width: Int, height: Int, offset: Int) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<height {
            // Top-left visual row index = (height-1-y) in bottom-left context space. Every channel
            // is keyed to (visualRow + offset) so frame B is a clean vertical scroll of frame A.
            let k = (height - 1 - y) + offset
            ctx.setFillColor(red: hashByte(k, shift: 0), green: hashByte(k, shift: 8),
                             blue: hashByte(k, shift: 16), alpha: 1)
            ctx.fill(CGRect(x: 0, y: y, width: width, height: 1))
        }
        return ctx.makeImage()!
    }

    @Test
    func detectsKnownScroll() {
        let a = gradient(width: 200, height: 400, offset: 0)
        let b = gradient(width: 200, height: 400, offset: 30) // scrolled down 30 px
        let sa = ScrollStitcher.grayRows(a, columns: ScrollStitcher.columns)!
        let sb = ScrollStitcher.grayRows(b, columns: ScrollStitcher.columns)!
        let dy = ScrollStitcher.bestShift(prev: sa, next: sb)
        #expect(abs(dy - 30) <= 2)
    }

    @Test
    func identicalFramesReportNoScroll() {
        let a = gradient(width: 120, height: 300, offset: 0)
        let sa = ScrollStitcher.grayRows(a, columns: ScrollStitcher.columns)!
        #expect(ScrollStitcher.bestShift(prev: sa, next: sa) == 0)
    }

    @Test
    func appendGrowsCanvasByRowCount() {
        let a = makeSolidTestImage(width: 100, height: 200)
        let b = makeSolidTestImage(width: 100, height: 200)
        let out = ScrollStitcher.append(canvas: a, next: b, rows: 40)
        #expect(out?.width == 100)
        #expect(out?.height == 240)
    }
}

@MainActor
struct AnnotationCloneTests {
    private let style = AnnotationStyle.makeDefault(imageWidth: 100)

    @Test
    func twoPointCloneIsIndependentAndKeepsType() {
        let rect = RectangleElement(start: CGPoint(x: 1, y: 2), style: style)
        rect.updateDrag(to: CGPoint(x: 10, y: 20))
        let copy = rect.clone()
        // Dynamic type is preserved through the single TwoPointElement.clone() override.
        #expect(copy is RectangleElement)
        // Mutating the original must not affect the clone (deep copy).
        rect.translate(by: CGSize(width: 100, height: 100))
        let copyBox = copy.boundingBox
        #expect(copyBox.origin.x == 1)
        #expect(copyBox.origin.y == 2)
        #expect(copyBox.width == 9)
        #expect(copyBox.height == 18)
    }

    @Test
    func textCloneCopiesContentAndIsIndependent() {
        let text = TextElement(origin: CGPoint(x: 5, y: 5), text: "hello", style: style)
        let copy = text.clone() as? TextElement
        #expect(copy?.text == "hello")
        text.text = "changed"
        text.translate(by: CGSize(width: 50, height: 0))
        #expect(copy?.text == "hello")
        #expect(copy?.origin.x == 5)
    }

    @Test
    func stepCloneKeepsNumberAndPosition() {
        let step = StepElement(center: CGPoint(x: 7, y: 8), number: 3, style: style)
        let copy = step.clone() as? StepElement
        #expect(copy?.number == 3)
        step.translate(by: CGSize(width: 10, height: 10))
        #expect(copy?.center.x == 7)
        #expect(copy?.center.y == 8)
    }
}

struct ImageTransformerTests {
    @Test
    func flipHorizontalMirrorsX() {
        let (t, size) = ImageTransformer.affine(.flipHorizontal, width: 100, height: 60)
        #expect(size == CGSize(width: 100, height: 60))
        #expect(CGPoint(x: 10, y: 20).applying(t) == CGPoint(x: 90, y: 20))
    }

    @Test
    func rotateRightSwapsDimsAndMapsCorners() {
        let (t, size) = ImageTransformer.affine(.rotateRight, width: 100, height: 60)
        #expect(size == CGSize(width: 60, height: 100))
        // Bottom-right (100,0) rotates clockwise to bottom-left (0,0).
        #expect(CGPoint(x: 100, y: 0).applying(t) == CGPoint(x: 0, y: 0))
        // Top-left (0,60) → top-right (60,100).
        #expect(CGPoint(x: 0, y: 60).applying(t) == CGPoint(x: 60, y: 100))
    }

    @Test
    func rotateLeftIsInverseOfRotateRight() {
        let (right, _) = ImageTransformer.affine(.rotateRight, width: 100, height: 60)
        // After rotateRight the image is 60×100; rotateLeft on that should bring a point home.
        let (left, _) = ImageTransformer.affine(.rotateLeft, width: 60, height: 100)
        let p = CGPoint(x: 30, y: 40)
        #expect(p.applying(right).applying(left) == p)
    }
}

@MainActor
struct ImageScalerTests {
    @Test
    func halvesAtFactorTwo() {
        let base = makeSolidTestImage(width: 100, height: 80)
        let out = ImageScaler.downscaled(base, by: 2)
        #expect(out?.width == 50)
        #expect(out?.height == 40)
    }

    @Test
    func factorOneReturnsOriginalSize() {
        let base = makeSolidTestImage(width: 64, height: 48)
        let out = ImageScaler.downscaled(base, by: 1)
        #expect(out?.width == 64)
        #expect(out?.height == 48)
    }
}

struct PIIMatcherTests {
    @Test
    func detectsCommonPII() {
        #expect(PIIMatcher.containsPII("contact me at jane.doe@example.com"))
        #expect(PIIMatcher.containsPII("call 555-123-4567"))
        #expect(PIIMatcher.containsPII("ip 192.168.1.42"))
        #expect(PIIMatcher.containsPII("SSN 123-45-6789"))
        #expect(PIIMatcher.containsPII("Authorization: Bearer abc.def-123"))
    }

    @Test
    func ignoresPlainText() {
        #expect(!PIIMatcher.containsPII("the quick brown fox"))
        #expect(!PIIMatcher.containsPII("version 2 of 3"))
    }
}

struct URLCommandTests {
    @Test
    func parsesKnownHosts() {
        #expect(URLCommand.parse(URL(string: "bettershutter://all-in-one")!) == .allInOne)
        #expect(URLCommand.parse(URL(string: "bettershutter://capture-region")!) == .captureRegion)
        #expect(URLCommand.parse(URL(string: "bettershutter://scrolling-capture")!) == .captureScrolling)
        #expect(URLCommand.parse(URL(string: "bettershutter://record-gif")!) == .recordGIF)
        #expect(URLCommand.parse(URL(string: "bettershutter://record-window")!) == .recordWindow)
        #expect(URLCommand.parse(URL(string: "bettershutter://pin")!) == .pinLast)
        #expect(URLCommand.parse(URL(string: "bettershutter://upload-last")!) == .uploadLast)
    }

    @Test
    func rejectsWrongSchemeAndFlagsUnknown() {
        #expect(URLCommand.parse(URL(string: "https://capture-region")!) == nil)
        #expect(URLCommand.parse(URL(string: "bettershutter://frobnicate")!) == .unknown("frobnicate"))
    }
}

struct PinGeometryTests {
    @Test
    func retinaHalvedAndFits() {
        // 2000×1000 px @2x = 1000×500 pt, fits within 2000×2000 → unchanged.
        let s = PinGeometry.fittedSize(pixelSize: CGSize(width: 2000, height: 1000), scale: 2,
                                       maxSize: CGSize(width: 2000, height: 2000))
        #expect(s == CGSize(width: 1000, height: 500))
    }

    @Test
    func capsToMaxKeepingAspect() {
        let s = PinGeometry.fittedSize(pixelSize: CGSize(width: 1000, height: 500), scale: 1,
                                       maxSize: CGSize(width: 400, height: 400))
        #expect(s == CGSize(width: 400, height: 200))
    }

    @Test
    func opacityClamped() {
        #expect(PinGeometry.clampOpacity(1.5) == 1.0)
        #expect(PinGeometry.clampOpacity(0.0) == 0.2)
        #expect(PinGeometry.clampOpacity(0.7) == 0.7)
    }
}

@MainActor
struct AnnotationProjectTests {
    @Test
    func roundTripPreservesElementsAndBase() throws {
        let base = makeSolidTestImage(width: 50, height: 40)
        let style = AnnotationStyle.makeDefault(imageWidth: 50)
        let rect = RectangleElement(start: CGPoint(x: 5, y: 6), style: style)
        rect.updateDrag(to: CGPoint(x: 25, y: 30))
        let text = TextElement(origin: CGPoint(x: 10, y: 12), text: "hi", style: style)
        let step = StepElement(center: CGPoint(x: 20, y: 20), number: 3, style: style)

        let project = try #require(AnnotationProjectIO.make(base: base, elements: [rect, text, step]))
        // Survive a full JSON encode/decode, like writing and reopening a .bsproj.
        let decoded = try JSONDecoder().decode(AnnotationProject.self, from: JSONEncoder().encode(project))
        let els = AnnotationProjectIO.elements(decoded)

        #expect(els.count == 3)
        #expect((els[0] as? RectangleElement)?.boundingBox == CGRect(x: 5, y: 6, width: 20, height: 24))
        #expect((els[1] as? TextElement)?.text == "hi")
        #expect((els[2] as? StepElement)?.number == 3)
        #expect(AnnotationProjectIO.baseImage(decoded)?.width == 50)
        #expect(AnnotationProjectIO.baseImage(decoded)?.height == 40)
    }

    @Test
    func colorSurvivesRoundTrip() {
        let red = NSColor.systemRed.usingColorSpace(.sRGB)!
        let back = CodableColor(NSColor.systemRed).nsColor
        #expect(abs(back.redComponent - red.redComponent) < 0.02)
        #expect(abs(back.blueComponent - red.blueComponent) < 0.02)
    }
}

@MainActor
struct AnnotationResizeTests {
    private let style = AnnotationStyle.makeDefault(imageWidth: 100)

    @Test
    func rectCornerHandleResizesKeepingOppositeCorner() {
        let rect = RectangleElement(start: CGPoint(x: 10, y: 10), style: style)
        rect.updateDrag(to: CGPoint(x: 30, y: 20)) // rect = (10,10,20,10)
        // Handle 2 is the top-right corner (maxX, maxY).
        let tr = rect.handlePoints()[2]
        #expect(tr == CGPoint(x: 30, y: 20))
        rect.moveHandle(2, to: CGPoint(x: 40, y: 25))
        let box = rect.boundingBox
        #expect(box == CGRect(x: 10, y: 10, width: 30, height: 15))
    }

    @Test
    func rectLeftEdgeHandleMovesOnlyX() {
        let rect = RectangleElement(start: CGPoint(x: 10, y: 10), style: style)
        rect.updateDrag(to: CGPoint(x: 30, y: 20))
        rect.moveHandle(7, to: CGPoint(x: 5, y: 99)) // left edge: y ignored
        let box = rect.boundingBox
        #expect(box.minX == 5)
        #expect(box.minY == 10)
        #expect(box.maxY == 20)
    }

    @Test
    func lineResizesByEndpoint() {
        let line = LineElement(start: CGPoint(x: 0, y: 0), style: style)
        line.updateDrag(to: CGPoint(x: 10, y: 10))
        #expect(line.handlePoints().count == 2)
        line.moveHandle(1, to: CGPoint(x: 20, y: 5)) // moves end only
        #expect(line.handlePoints()[0] == CGPoint(x: 0, y: 0))
        #expect(line.handlePoints()[1] == CGPoint(x: 20, y: 5))
    }
}

@MainActor
struct GIFEncoderTests {
    @Test
    func encodesFramesToGIF() {
        let frames = [
            makeSolidTestImage(width: 8, height: 8),
            makeSolidTestImage(width: 8, height: 8),
            makeSolidTestImage(width: 8, height: 8),
        ]
        let data = GIFEncoder.encode(frames: frames, frameDelay: 0.1)
        #expect(data != nil)
        // GIF magic header "GIF8".
        let prefix = data?.prefix(4)
        #expect(prefix.map { Array($0) } == Array("GIF8".utf8))
    }

    @Test
    func emptyFramesReturnsNil() {
        #expect(GIFEncoder.encode(frames: [], frameDelay: 0.1) == nil)
    }
}

@MainActor
struct KeystrokeFormatterTests {
    @Test
    func combinesModifiersInCanonicalOrder() {
        let mods: NSEvent.ModifierFlags = [.command, .shift]
        #expect(KeystrokeFormatter.display(modifiers: mods, keyCode: 0, characters: "a") == "⇧⌘A")
    }

    @Test
    func specialKeysUseSymbols() {
        #expect(KeystrokeFormatter.display(modifiers: [], keyCode: 53, characters: nil) == "⎋")   // escape
        #expect(KeystrokeFormatter.display(modifiers: [], keyCode: 49, characters: " ") == "␣")    // space
        #expect(KeystrokeFormatter.display(modifiers: [.command], keyCode: 36, characters: "\r") == "⌘↩")
    }
}

@MainActor
struct ColorPaletteTests {
    @Test
    func prependsDedupsAndCaps() {
        var list = ColorPalette.add("#FF0000", to: [])
        list = ColorPalette.add("#00FF00", to: list)
        list = ColorPalette.add("#ff0000", to: list)   // dup (case-insensitive) -> moves to front
        #expect(list == ["#FF0000", "#00FF00"])
        // Cap at max.
        var big: [String] = []
        for i in 0..<20 { big = ColorPalette.add(String(format: "#0000%02X", i), to: big, max: 12) }
        #expect(big.count == 12)
        #expect(big.first == "#000013")   // newest
    }

    @Test @MainActor
    func hexRoundTrips() {
        let color = NSColor(hexString: "#3366CC")
        #expect(color != nil)
        #expect(color?.hexString == "#3366CC")
    }
}

@MainActor
struct WebPFormatTests {
    @Test
    func webpEnumProperties() {
        #expect(ImageFileFormat.webp.fileExtension == "webp")
        #expect(ImageFileFormat.webp.isLossy)
        #expect(ImageFileFormat.allCases.contains(.webp))
    }

    @Test
    func encodeProducesWebPOrNilGracefully() {
        let image = makeSolidTestImage(width: 8, height: 8)
        // ImageIO may or may not advertise a WebP writer; if it does, bytes must carry the RIFF/WEBP
        // container magic. If it can't encode, nil is the documented graceful fallback.
        if let data = ImageEncoder.encode(image, as: .webp), data.count >= 12 {
            let bytes = Array(data.prefix(12))
            #expect(Array(bytes[0..<4]) == Array("RIFF".utf8))
            #expect(Array(bytes[8..<12]) == Array("WEBP".utf8))
        }
    }
}

struct AngleSnapTests {
    @Test
    func snapsNearHorizontalToHorizontal() {
        let snapped = AngleSnap.snap(start: .zero, end: CGPoint(x: 10, y: 1))
        #expect(abs(snapped.y) < 0.001)               // pinned to 0°
        #expect(abs(snapped.x - hypot(10, 1)) < 0.001) // length preserved
    }

    @Test
    func snapsNearVerticalToVertical() {
        let snapped = AngleSnap.snap(start: .zero, end: CGPoint(x: 1, y: 10))
        #expect(abs(snapped.x) < 0.001)               // pinned to 90°
        #expect(abs(snapped.y - hypot(1, 10)) < 0.001)
    }

    @Test
    func diagonalStaysDiagonal() {
        let snapped = AngleSnap.snap(start: .zero, end: CGPoint(x: 10, y: 9))
        #expect(abs(snapped.x - snapped.y) < 0.001)   // 45°
    }
}

struct MeasureElementTests {
    @Test
    func pixelLengthIsEuclidean() {
        #expect(MeasureElement.pixelLength(from: .zero, to: CGPoint(x: 3, y: 4)) == 5)
        #expect(MeasureElement.pixelLength(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 10, y: 10)) == 0)
    }

    @Test
    func labelRoundsToWholePixels() {
        #expect(MeasureElement.label(from: .zero, to: CGPoint(x: 100, y: 0)) == "100 px")
        #expect(MeasureElement.label(from: .zero, to: CGPoint(x: 3, y: 4)) == "5 px")
    }
}

@MainActor
struct PixelateScaleTests {
    // NOTE: re-pointed from a removed `secureScale(width:height:)` API to the current
    // `blockSize(strength:imageSize:)`, which drives mosaic coarseness from the strength slider
    // scaled to the image (not the region) with an 8px floor.
    @Test
    func weakestStrengthStillFloorsToEightPx() {
        // Even strength 0 averages into at least an 8px block so faint text can't be reconstructed.
        #expect(PixelateElement.blockSize(strength: 0, imageSize: CGSize(width: 200, height: 20)) == 8)
    }

    @Test
    func blockScalesWithStrengthAndImage() {
        // Small image: min dim 160/8 = 20 < 40 floor → 40 at full strength.
        let small = PixelateElement.blockSize(strength: 1, imageSize: CGSize(width: 200, height: 160))
        #expect(small == 40)
        // Large image: min dim 480/8 = 60 → 60 at full strength, and coarser than the small image.
        let large = PixelateElement.blockSize(strength: 1, imageSize: CGSize(width: 800, height: 480))
        #expect(large == 60)
        #expect(large > small)
    }
}

struct HighlightSnapTests {
    // Three text lines stacked vertically (image-pixel, bottom-left), each 80 wide × 10 tall.
    private let lines = [
        CGRect(x: 10, y: 80, width: 80, height: 10),   // top line
        CGRect(x: 10, y: 60, width: 80, height: 10),   // middle
        CGRect(x: 10, y: 40, width: 80, height: 10),   // bottom
    ]

    @Test
    func snapsToOverlappedLinesClampedHorizontally() throws {
        // Drag covers the top two lines, x 20…70.
        let drawn = CGRect(x: 20, y: 55, width: 50, height: 37)   // y 55…92
        let snapped = try #require(HighlightSnap.snap(drawn: drawn, lines: lines))
        #expect(snapped.minX == 20)
        #expect(snapped.maxX == 70)
        #expect(snapped.minY == 60)   // bottom of middle line
        #expect(snapped.maxY == 90)   // top of top line
    }

    @Test
    func barelyClippedLineIsExcluded() {
        // Drag only nicks the top 2px of the top line (<30% of its 10px height).
        let drawn = CGRect(x: 20, y: 88, width: 50, height: 8)    // y 88…96
        #expect(HighlightSnap.snap(drawn: drawn, lines: lines) == nil)
    }

    @Test
    func noTextReturnsNil() {
        let drawn = CGRect(x: 200, y: 200, width: 30, height: 30)
        #expect(HighlightSnap.snap(drawn: drawn, lines: lines) == nil)
    }
}

struct StepFormatTests {
    @Test
    func decimalIsPlain() {
        #expect(StepFormat.decimal.string(for: 1) == "1")
        #expect(StepFormat.decimal.string(for: 42) == "42")
    }

    @Test
    func alphabeticWrapsPastZ() {
        #expect(StepFormat.alphabetic.string(for: 1) == "A")
        #expect(StepFormat.alphabetic.string(for: 26) == "Z")
        #expect(StepFormat.alphabetic.string(for: 27) == "AA")
        #expect(StepFormat.alphabetic.string(for: 28) == "AB")
        #expect(StepFormat.alphabetic.string(for: 52) == "AZ")
        #expect(StepFormat.alphabetic.string(for: 53) == "BA")
    }

    @Test
    func romanNumerals() {
        #expect(StepFormat.roman.string(for: 1) == "I")
        #expect(StepFormat.roman.string(for: 4) == "IV")
        #expect(StepFormat.roman.string(for: 9) == "IX")
        #expect(StepFormat.roman.string(for: 40) == "XL")
        #expect(StepFormat.roman.string(for: 1990) == "MCMXC")
    }

    @Test @MainActor
    func badgeLabelHonorsFormatAndStart() {
        let style = AnnotationStyle.makeDefault(imageWidth: 100)
        let step = StepElement(center: .zero, number: 3, style: style, format: .alphabetic, start: 1)
        #expect(step.label == "C")        // start 1, sequence 3 -> 3rd letter
        let offset = StepElement(center: .zero, number: 1, style: style, format: .decimal, start: 5)
        #expect(offset.label == "5")      // custom start
    }
}

struct StoredRegionTests {
    @Test
    func roundTripsRectAndDisplay() throws {
        let rect = CGRect(x: -120.5, y: 40, width: 800, height: 600)
        let stored = StoredRegion(rect: rect, displayID: 7)
        let decoded = try JSONDecoder().decode(StoredRegion.self, from: JSONEncoder().encode(stored))
        #expect(decoded.rect == rect)
        #expect(decoded.displayID == 7)
    }
}

@MainActor
struct BeautifyPresetTests {
    @Test
    func gradientPresetRoundTrips() throws {
        var style = BeautifyStyle.makeDefault()
        style.background = .gradient([.red, .blue], angleDegrees: 30)
        style.paddingFraction = 0.12
        style.cornerFraction = 0.04
        style.shadow = false
        style.windowFrame = .dark
        style.targetAspect = 16.0 / 9.0

        let preset = BeautifyPreset(name: "Test", style: style)
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(BeautifyPreset.self, from: data)
        let applied = decoded.applied(to: .makeDefault())

        #expect(abs(applied.paddingFraction - 0.12) < 1e-9)
        #expect(abs(applied.cornerFraction - 0.04) < 1e-9)
        #expect(applied.shadow == false)
        #expect(applied.windowFrame == .dark)
        #expect(abs((applied.targetAspect ?? 0) - 16.0 / 9.0) < 1e-9)
        if case .gradient(let colors, let angle) = applied.background {
            #expect(colors.count == 2)
            #expect(angle == 30)
        } else {
            Issue.record("expected gradient background")
        }
    }

    @Test
    func solidPresetRoundTrips() throws {
        var style = BeautifyStyle.makeDefault()
        style.background = .solid(NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        let preset = BeautifyPreset(name: "Solid", style: style)
        let decoded = try JSONDecoder().decode(BeautifyPreset.self, from: JSONEncoder().encode(preset))
        let applied = decoded.applied(to: .makeDefault())

        if case .solid(let color) = applied.background, let s = color.usingColorSpace(.sRGB) {
            #expect(abs(s.redComponent - 0.2) < 0.01)
            #expect(abs(s.greenComponent - 0.4) < 0.01)
            #expect(abs(s.blueComponent - 0.6) < 0.01)
        } else {
            Issue.record("expected solid background")
        }
    }
}

@MainActor
struct SmartEraseTests {
    private let style = AnnotationStyle.makeDefault(imageWidth: 100)

    @Test
    func flattenKeepsSizeAndClones() {
        let base = makeSolidTestImage(width: 60, height: 50)
        let erase = SmartEraseElement(start: CGPoint(x: 10, y: 10), style: style)
        erase.updateDrag(to: CGPoint(x: 40, y: 35))
        let out = AnnotationRenderer.flatten(base: base, elements: [erase], ciContext: CIContext())
        #expect(out?.width == 60 && out?.height == 50)
        #expect(erase.clone() is SmartEraseElement)
    }

    @Test
    func borderAverageMatchesSolidBackground() {
        // makeSolidTestImage paints solid blue → the border ring averages to blue.
        let base = makeSolidTestImage(width: 40, height: 40)
        let color = SmartEraseElement.borderAverageColor(
            of: base, region: CGRect(x: 12, y: 12, width: 16, height: 16),
            imageSize: CGSize(width: 40, height: 40), ciContext: CIContext())
        let comps = color.components ?? []
        #expect(comps.count >= 3)
        #expect(comps[2] > 0.8)   // blue dominant
        #expect(comps[0] < 0.2)   // little red
    }
}

@MainActor
struct TextFormattingTests {
    private let style = AnnotationStyle.makeDefault(imageWidth: 100)

    @Test
    func projectRoundTripPreservesFormatting() throws {
        let base = makeSolidTestImage(width: 60, height: 40)
        var fmt = TextFormatting()
        fmt.bold = true; fmt.underline = true; fmt.outlined = true
        fmt.background = NSColor.systemYellow.withAlphaComponent(0.4)
        let text = TextElement(origin: CGPoint(x: 4, y: 5), text: "Hi", style: style, format: fmt)
        let project = try #require(AnnotationProjectIO.make(base: base, elements: [text]))
        let decoded = try JSONDecoder().decode(AnnotationProject.self, from: JSONEncoder().encode(project))
        let back = try #require(AnnotationProjectIO.elements(decoded).first as? TextElement)
        #expect(back.format.bold && back.format.underline && back.format.outlined)
        #expect(!back.format.italic && !back.format.strikethrough)
        #expect(back.format.background != nil)
    }

    @Test
    func flattenWithFormattedTextKeepsSize() {
        let base = makeSolidTestImage(width: 80, height: 40)
        var fmt = TextFormatting()
        fmt.strikethrough = true; fmt.italic = true
        let text = TextElement(origin: CGPoint(x: 5, y: 10), text: "abc", style: style, format: fmt)
        let out = AnnotationRenderer.flatten(base: base, elements: [text], ciContext: CIContext())
        #expect(out?.width == 80 && out?.height == 40)
    }
}

struct ImageAdjustmentsTests {
    @Test
    func identityFlag() {
        #expect(ImageAdjustments().isIdentity)
        var a = ImageAdjustments(); a.saturation = 0.5
        #expect(!a.isIdentity)
    }

    @Test @MainActor
    func identityReturnsInputUnchangedSize() {
        let base = makeSolidTestImage(width: 20, height: 10)
        let out = ImageAdjustments().apply(to: base, ciContext: CIContext())
        #expect(out.width == 20 && out.height == 10)
    }

    @Test @MainActor
    func adjustmentPreservesSize() {
        let base = makeSolidTestImage(width: 32, height: 24)
        var a = ImageAdjustments()
        a.brightness = 0.2; a.contrast = 1.3; a.saturation = 1.5; a.sharpness = 0.5
        let out = a.apply(to: base, ciContext: CIContext())
        #expect(out.width == 32 && out.height == 24)
    }
}

@MainActor
struct WatermarkElementTests {
    private let style = AnnotationStyle.makeDefault(imageWidth: 120)

    @Test
    func tiledFlattensAtSameSize() {
        let base = makeSolidTestImage(width: 120, height: 90)
        let wm = WatermarkElement(text: "Confidential", tiled: true, anchor: .zero,
                                  imageSize: CGSize(width: 120, height: 90), style: style)
        let out = AnnotationRenderer.flatten(base: base, elements: [wm], ciContext: CIContext())
        #expect(out?.width == 120)
        #expect(out?.height == 90)
        #expect(wm.clone() is WatermarkElement)
    }

    @Test
    func projectRoundTripPreservesWatermark() throws {
        let base = makeSolidTestImage(width: 60, height: 40)
        let wm = WatermarkElement(text: "Draft", tiled: false,
                                  anchor: CGPoint(x: 5, y: 6),
                                  imageSize: CGSize(width: 60, height: 40), style: style, opacity: 0.3)
        let project = try #require(AnnotationProjectIO.make(base: base, elements: [wm]))
        let decoded = try JSONDecoder().decode(AnnotationProject.self, from: JSONEncoder().encode(project))
        let back = try #require(AnnotationProjectIO.elements(decoded).first as? WatermarkElement)
        #expect(back.text == "Draft")
        #expect(back.tiled == false)
        #expect(back.imageSize == CGSize(width: 60, height: 40))
        #expect(abs(back.opacity - 0.3) < 1e-6)
    }
}

@MainActor
struct PenElementTests {
    private let style = AnnotationStyle.makeDefault(imageWidth: 100)

    @Test
    func updateDragAppendsDistinctPoints() {
        let pen = PenElement(start: CGPoint(x: 0, y: 0), style: style)
        pen.updateDrag(to: CGPoint(x: 0, y: 0.5))   // too close → dropped
        pen.updateDrag(to: CGPoint(x: 10, y: 0))
        pen.updateDrag(to: CGPoint(x: 20, y: 5))
        #expect(pen.points.count == 3)
    }

    @Test
    func cloneIsIndependentAndKeepsType() {
        let marker = MarkerElement(start: CGPoint(x: 1, y: 1), style: style)
        marker.updateDrag(to: CGPoint(x: 30, y: 10))
        let copy = marker.clone()
        #expect(copy is MarkerElement)
        marker.translate(by: CGSize(width: 100, height: 0))
        #expect((copy as? MarkerElement)?.points.first?.x == 1)
        // The marker is broader and more translucent than a plain pen.
        #expect(MarkerElement(start: .zero, style: style).widthScale > PenElement(start: .zero, style: style).widthScale)
    }

    @Test
    func hitTestMatchesNearStrokeNotFar() {
        let pen = PenElement(start: CGPoint(x: 0, y: 0), style: style)
        pen.updateDrag(to: CGPoint(x: 100, y: 0))
        #expect(pen.hitTest(CGPoint(x: 50, y: 2)))      // on the line
        #expect(!pen.hitTest(CGPoint(x: 50, y: 80)))    // far away
    }

    @Test
    func projectRoundTripPreservesPenPoints() throws {
        let base = makeSolidTestImage(width: 50, height: 40)
        let pen = PenElement(start: CGPoint(x: 2, y: 2), style: style)
        pen.updateDrag(to: CGPoint(x: 20, y: 18))
        let project = try #require(AnnotationProjectIO.make(base: base, elements: [pen]))
        let decoded = try JSONDecoder().decode(AnnotationProject.self, from: JSONEncoder().encode(project))
        let els = AnnotationProjectIO.elements(decoded)
        #expect((els.first as? PenElement)?.points.count == 2)
    }
}

struct SelectionAspectTests {
    @Test
    func squareLockFromWidthDominantDrag() {
        // Drag right-and-up, wider than tall → height grows to match width (1:1).
        let r = SelectionModel.rect(from: .zero, to: CGPoint(x: 100, y: 40), aspect: 1)
        #expect(r == CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    @Test
    func sixteenNineLockFromHeightDominantDrag() {
        // Tall drag with 16:9 lock → width derived from height.
        let r = SelectionModel.rect(from: .zero, to: CGPoint(x: 10, y: 90), aspect: 16.0 / 9.0)
        #expect(abs(r.width - 160) < 1e-6)
        #expect(abs(r.height - 90) < 1e-6)
    }

    @Test
    func anchorPinnedWhenDraggingUpLeft() {
        // Dragging toward negative x/y keeps the anchor corner pinned at the far edge.
        let r = SelectionModel.rect(from: CGPoint(x: 200, y: 200), to: CGPoint(x: 100, y: 190), aspect: 1)
        #expect(r.maxX == 200)
        #expect(r.maxY == 200)
        #expect(r.width == 100 && r.height == 100)
    }

    @Test
    func nonPositiveAspectFallsBackToFree() {
        let r = SelectionModel.rect(from: .zero, to: CGPoint(x: 30, y: 70), aspect: 0)
        #expect(r == CGRect(x: 0, y: 0, width: 30, height: 70))
    }
}

struct CloudConfigTests {
    @Test
    func pathStyleObjectURL() {
        var c = S3Config()
        c.bucket = "shots"; c.endpointHost = "s3.amazonaws.com"; c.usePathStyle = true
        #expect(c.objectURL(key: "a.png")?.absoluteString == "https://s3.amazonaws.com/shots/a.png")
    }

    @Test
    func virtualHostedObjectURL() {
        var c = S3Config()
        c.bucket = "shots"; c.endpointHost = "s3.amazonaws.com"; c.usePathStyle = false
        #expect(c.objectURL(key: "a.png")?.absoluteString == "https://shots.s3.amazonaws.com/a.png")
    }

    @Test
    func publicBaseURLOverridesAndTrimsSlash() {
        var c = S3Config()
        c.bucket = "shots"; c.endpointHost = "s3.amazonaws.com"; c.publicBaseURL = "https://cdn.example.com/"
        #expect(c.objectURL(key: "a.png")?.absoluteString == "https://cdn.example.com/a.png")
    }

    @Test @MainActor
    func keyFormat() {
        #expect(CloudUploadService.makeKey(stamp: "2026-06-14-090000", random: "ab12cd34", ext: "png")
                == "2026-06-14-090000-ab12cd34.png")
    }
}

struct SigV4Tests {
    @Test
    func derivesKnownSigningKey() {
        // AWS's published "derive a signing key" example vector.
        let key = SigV4.signingKey(secret: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
                                   dateStamp: "20120215", region: "us-east-1", service: "iam")
        #expect(SigV4.hex(key) == "f4780e2d9f65fa895f9c67b32ce1baf0b0d8a43505a000a1a9e090d414db404d")
    }

    @Test
    func sha256OfEmptyPayload() {
        #expect(SigV4.sha256Hex(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test
    func authorizationHeaderHasExpectedShape() {
        let r = SigV4.Request(
            method: "PUT", host: "bucket.s3.us-east-1.amazonaws.com", path: "/key.png", query: "",
            headers: ["host": "bucket.s3.us-east-1.amazonaws.com",
                      "x-amz-date": "20240101T000000Z",
                      "x-amz-content-sha256": SigV4.sha256Hex(Data())],
            payloadHashHex: SigV4.sha256Hex(Data()),
            date: Date(timeIntervalSince1970: 1_704_067_200), region: "us-east-1", service: "s3",
            secretKey: "secret", accessKey: "AKIDEXAMPLE")
        let header = SigV4.authorizationHeader(r)
        #expect(header.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/"))
        #expect(header.contains("SignedHeaders=host;x-amz-content-sha256;x-amz-date"))
        #expect(header.contains("Signature="))
    }
}

struct CursorTrackTests {
    @Test
    func interpolatesBetweenSamples() {
        let track = CursorTrack(samples: [
            CursorSample(t: 0, x: 0, y: 0),
            CursorSample(t: 1, x: 1, y: 0.5),
        ])
        let p = track.point(at: 0.5)
        #expect(abs((p?.x ?? -1) - 0.5) < 1e-9)
        #expect(abs((p?.y ?? -1) - 0.25) < 1e-9)
    }

    @Test
    func clampsToEnds() {
        let track = CursorTrack(samples: [
            CursorSample(t: 1, x: 0.2, y: 0.3), CursorSample(t: 2, x: 0.8, y: 0.9),
        ])
        #expect(track.point(at: 0)?.x == 0.2)
        #expect(track.point(at: 5)?.x == 0.8)
    }

    @Test
    func emptyTrackReturnsNil() {
        #expect(CursorTrack(samples: []).point(at: 1) == nil)
    }
}

@MainActor
struct VideoZoomTests {
    @Test
    func zoomCropReturnsFullFrameSize() {
        let img = CIImage(cgImage: makeSolidTestImage(width: 200, height: 100))
        // Focus at the corner; the clamp must keep the crop inside and rescale to the full frame.
        let out = VideoBeautify.zoomed(img, focus: CGPoint(x: 1, y: 1), zoom: 2)
        #expect(abs(out.extent.width - 200) < 1)
        #expect(abs(out.extent.height - 100) < 1)
    }

    @Test
    func zoomOneIsIdentity() {
        let img = CIImage(cgImage: makeSolidTestImage(width: 50, height: 50))
        let out = VideoBeautify.zoomed(img, focus: CGPoint(x: 0.5, y: 0.5), zoom: 1)
        #expect(out.extent == img.extent)
    }
}

struct VideoBeautifyLayoutTests {
    @Test
    func paddingAddsEvenBorder() {
        let (size, scale, inset) = VideoBeautify.layout(srcW: 1920, srcH: 1080, paddingFraction: 0.1, targetHeight: nil)
        #expect(size.width == 2136 && size.height == 1296)   // pad = 108 each side
        #expect(scale == 1)
        #expect(inset == 108)
        #expect(Int(size.width) % 2 == 0 && Int(size.height) % 2 == 0)
    }

    @Test
    func targetHeightScalesProportionally() {
        let (size, scale, inset) = VideoBeautify.layout(srcW: 1000, srcH: 1000, paddingFraction: 0.1, targetHeight: 600)
        #expect(size.height == 600)
        #expect(abs(scale - 0.5) < 1e-9)
        #expect(abs(inset - 50) < 1e-9)
    }

    @Test
    func zeroPaddingRoundsToEvenSourceSize() {
        let (size, _, inset) = VideoBeautify.layout(srcW: 1281, srcH: 721, paddingFraction: 0, targetHeight: nil)
        #expect(inset == 0)
        #expect(size.width == 1280 && size.height == 720)
    }
}

@MainActor
struct PerspectiveMockupTests {
    @Test
    func tiltRendersOutput() {
        let base = makeSolidTestImage(width: 80, height: 60)
        var style = BeautifyStyle.makeDefault()
        style.perspective = .right
        #expect(BeautifyRenderer.render(base: base, style: style) != nil)
    }

    @Test
    func presetRoundTripPreservesPerspective() throws {
        var style = BeautifyStyle.makeDefault()
        style.perspective = .left
        let preset = BeautifyPreset(name: "Tilt", style: style)
        let decoded = try JSONDecoder().decode(BeautifyPreset.self, from: JSONEncoder().encode(preset))
        #expect(decoded.applied(to: .makeDefault()).perspective == .left)
    }

    @Test
    func legacyPresetWithoutPerspectiveDecodesFlat() throws {
        // Presets saved before 3D existed lack the key; the optional must still decode to flat.
        let json = """
        {"name":"Old","paddingFraction":0.08,"cornerFraction":0.03,"shadow":true,\
        "shadowFraction":0.05,"windowFrame":0}
        """
        let decoded = try JSONDecoder().decode(BeautifyPreset.self, from: Data(json.utf8))
        #expect(decoded.applied(to: .makeDefault()).perspective == .none)
    }
}

@MainActor
struct MeshGradientTests {
    @Test
    func meshPresetRoundTrips() throws {
        var style = BeautifyStyle.makeDefault()
        style.background = .mesh([.systemPink, .systemBlue, .systemGreen])
        let preset = BeautifyPreset(name: "Mesh", style: style)
        let decoded = try JSONDecoder().decode(BeautifyPreset.self, from: JSONEncoder().encode(preset))
        let applied = decoded.applied(to: .makeDefault())
        if case .mesh(let colors) = applied.background { #expect(colors.count == 3) }
        else { Issue.record("expected mesh background") }
    }

    @Test
    func meshRendersLargerThanInput() {
        let base = makeSolidTestImage(width: 80, height: 60)
        var style = BeautifyStyle.makeDefault()
        style.background = .mesh([.systemPink, .systemBlue])
        let out = BeautifyRenderer.render(base: base, style: style)
        #expect(out != nil)
        #expect((out?.width ?? 0) > 80)
    }

    @Test
    func presetLibraryIsExpandedAndHasMesh() {
        #expect(BackgroundPreset.all.count >= 28)
        #expect(BackgroundPreset.all.contains { if case .mesh = $0.fill { return true }; return false })
    }
}

@MainActor
struct FloatPreviewCardSizeTests {
    @Test
    func cardIsAlways16x9() {
        // Every capture aspect maps to the same fixed 16:9 tile.
        for px in [CGSize(width: 1920, height: 1080),   // 16:9
                   CGSize(width: 800, height: 2000),     // portrait
                   CGSize(width: 4000, height: 400),     // ultrawide
                   CGSize.zero] {                         // degenerate
            let size = FloatPreviewView.cardSize(for: px)
            #expect(size.width == FloatPreviewView.cardWidth)
            #expect(size.height == FloatPreviewView.cardHeight)
            #expect(abs(size.width / size.height - 16.0 / 9.0) < 0.001)
        }
    }
}
