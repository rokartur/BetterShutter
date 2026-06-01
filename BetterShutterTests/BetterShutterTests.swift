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
        #expect(URLCommand.parse(URL(string: "bettershutter://capture-region")!) == .captureRegion)
        #expect(URLCommand.parse(URL(string: "bettershutter://scrolling-capture")!) == .captureScrolling)
        #expect(URLCommand.parse(URL(string: "bettershutter://record-gif")!) == .recordGIF)
        #expect(URLCommand.parse(URL(string: "bettershutter://pin")!) == .pinLast)
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

struct PixelateScaleTests {
    @Test
    func thinStripGetsCoarseFloor() {
        // A 200×20 text strip must still be averaged into ≥16px blocks (not the old 8px).
        #expect(PixelateElement.secureScale(width: 200, height: 20) == 16)
    }

    @Test
    func largeRegionScalesUp() {
        let scale = PixelateElement.secureScale(width: 600, height: 480)
        #expect(scale == 80)            // min dim 480 / 6
        #expect(scale > 16)
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
