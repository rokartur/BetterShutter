import Testing
import AppKit
import CoreGraphics
import CoreImage
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
