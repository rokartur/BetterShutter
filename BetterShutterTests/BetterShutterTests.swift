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
