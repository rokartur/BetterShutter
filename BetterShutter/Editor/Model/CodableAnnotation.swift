import AppKit
import ImageIO

/// Serialisable form of the editor's annotation layers + their base image, so a capture can be
/// saved as a re-editable project (`.bsproj`) and reopened with every annotation still editable —
/// BetterShutter's local answer to CleanShot's editable project files.
///
/// The plain `Codable` structs are `nonisolated`; converting to/from the live `@MainActor`
/// `AnnotationElement` graph happens in the `@MainActor` helpers on `AnnotationProjectIO`.

nonisolated struct CodableColor: Codable, Sendable {
    var r, g, b, a: Double

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .black
        r = Double(c.redComponent); g = Double(c.greenComponent)
        b = Double(c.blueComponent); a = Double(c.alphaComponent)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
    }
}

nonisolated struct CodableStyle: Codable, Sendable {
    var color: CodableColor
    var strokeWidth: Double
    var fontSize: Double
    var fillMode: String?
    var dash: String?
    var arrowStyle: String?
    var cornerRadius: Double?
    var redactionStrength: Double?
}

/// One annotation, flattened to a tagged record. Only the fields relevant to `kind` are populated.
nonisolated struct CodableAnnotation: Codable, Sendable {
    var kind: String
    var style: CodableStyle
    var start: CGPoint?     // two-point shapes
    var end: CGPoint?
    var origin: CGPoint?    // text
    var text: String?
    var center: CGPoint?    // step / loupe
    var number: Int?
    var stepFormat: String? // step numbering format
    var stepStart: Int?     // step first-label value
    var radius: Double?     // loupe
    var zoom: Double?       // loupe
    var rotation: Double?   // any element, radians
    var imagePNG: Data?     // composed image (base64 in JSON)
}

nonisolated struct AnnotationProject: Codable, Sendable {
    var version: Int
    var imagePNG: Data              // unflattened base capture (PNG; base64 in JSON)
    var annotations: [CodableAnnotation]
}

@MainActor
enum AnnotationProjectIO {
    static let fileExtension = "bsproj"

    // MARK: Build / parse

    static func make(base: CGImage, elements: [AnnotationElement]) -> AnnotationProject? {
        guard let png = ImageEncoder.encode(base, as: .png) else { return nil }
        return AnnotationProject(version: 1, imagePNG: png, annotations: elements.compactMap(encode))
    }

    static func baseImage(_ project: AnnotationProject) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(project.imagePNG as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func elements(_ project: AnnotationProject) -> [AnnotationElement] {
        project.annotations.compactMap(decode)
    }

    // MARK: Disk

    static func write(_ project: AnnotationProject, to url: URL) throws {
        try JSONEncoder().encode(project).write(to: url)
    }

    static func read(_ url: URL) throws -> AnnotationProject {
        try JSONDecoder().decode(AnnotationProject.self, from: Data(contentsOf: url))
    }

    // MARK: Element <-> record

    static func encode(_ e: AnnotationElement) -> CodableAnnotation? {
        guard var record = encodeKind(e) else { return nil }
        record.rotation = e.rotation == 0 ? nil : Double(e.rotation)
        return record
    }

    private static func encodeKind(_ e: AnnotationElement) -> CodableAnnotation? {
        let style = CodableStyle(color: CodableColor(e.style.color),
                                 strokeWidth: Double(e.style.strokeWidth),
                                 fontSize: Double(e.style.fontSize),
                                 fillMode: e.style.fillMode.rawValue,
                                 dash: e.style.dash.rawValue,
                                 arrowStyle: e.style.arrowStyle.rawValue,
                                 cornerRadius: Double(e.style.cornerRadius),
                                 redactionStrength: Double(e.style.redactionStrength))
        func twoPoint(_ kind: String, _ t: TwoPointElement) -> CodableAnnotation {
            CodableAnnotation(kind: kind, style: style, start: t.start, end: t.end)
        }
        switch e {
        case let x as RectangleElement: return twoPoint("rectangle", x)
        case let x as EllipseElement:   return twoPoint("ellipse", x)
        case let x as MeasureElement:   return twoPoint("measure", x)
        case let x as LineElement:      return twoPoint("line", x)
        case let x as ArrowElement:     return twoPoint("arrow", x)
        case let x as HighlightElement: return twoPoint("highlight", x)
        case let x as PixelateElement:  return twoPoint("pixelate", x)
        case let x as BlurElement:      return twoPoint("blur", x)
        case let x as BlackoutElement:  return twoPoint("blackout", x)
        case let x as SpotlightElement: return twoPoint("spotlight", x)
        case let x as TextElement:
            return CodableAnnotation(kind: "text", style: style, origin: x.origin, text: x.text)
        case let x as StepElement:
            return CodableAnnotation(kind: "step", style: style, center: x.center, number: x.number,
                                     stepFormat: x.format.rawValue, stepStart: x.start)
        case let x as LoupeElement:
            return CodableAnnotation(kind: "loupe", style: style, center: x.center,
                                     radius: Double(x.radius), zoom: Double(x.zoom))
        case let x as StampElement:
            return CodableAnnotation(kind: "stamp", style: style, text: x.emoji, center: x.center)
        case let x as ImageElement:
            return CodableAnnotation(kind: "image", style: style,
                                     start: CGPoint(x: x.frame.minX, y: x.frame.minY),
                                     end: CGPoint(x: x.frame.maxX, y: x.frame.maxY),
                                     imagePNG: ImageEncoder.encode(x.image, as: .png))
        default:
            return nil
        }
    }

    static func decode(_ c: CodableAnnotation) -> AnnotationElement? {
        guard let element = decodeKind(c) else { return nil }
        element.rotation = CGFloat(c.rotation ?? 0)
        return element
    }

    private static func decodeKind(_ c: CodableAnnotation) -> AnnotationElement? {
        var style = AnnotationStyle(color: c.style.color.nsColor,
                                    strokeWidth: CGFloat(c.style.strokeWidth),
                                    fontSize: CGFloat(c.style.fontSize),
                                    fillMode: FillMode(rawValue: c.style.fillMode ?? "stroke") ?? .stroke,
                                    dash: DashStyle(rawValue: c.style.dash ?? "solid") ?? .solid)
        style.arrowStyle = ArrowStyle(rawValue: c.style.arrowStyle ?? "straight") ?? .straight
        style.cornerRadius = CGFloat(c.style.cornerRadius ?? 0)
        style.redactionStrength = CGFloat(c.style.redactionStrength ?? 0.5)
        func twoPoint<T: TwoPointElement>(_ type: T.Type) -> T {
            let e = T(start: c.start ?? .zero, style: style)
            e.end = c.end ?? c.start ?? .zero
            return e
        }
        switch c.kind {
        case "rectangle": return twoPoint(RectangleElement.self)
        case "ellipse":   return twoPoint(EllipseElement.self)
        case "line":      return twoPoint(LineElement.self)
        case "measure":   return twoPoint(MeasureElement.self)
        case "arrow":     return twoPoint(ArrowElement.self)
        case "highlight": return twoPoint(HighlightElement.self)
        case "pixelate":  return twoPoint(PixelateElement.self)
        case "blur":      return twoPoint(BlurElement.self)
        case "blackout":  return twoPoint(BlackoutElement.self)
        case "spotlight": return twoPoint(SpotlightElement.self)
        case "text":      return TextElement(origin: c.origin ?? .zero, text: c.text ?? "", style: style)
        case "step":
            return StepElement(center: c.center ?? .zero, number: c.number ?? 1, style: style,
                               format: StepFormat(rawValue: c.stepFormat ?? "decimal") ?? .decimal,
                               start: c.stepStart ?? 1)
        case "loupe":
            let loupe = LoupeElement(center: c.center ?? .zero, style: style, zoom: CGFloat(c.zoom ?? 2))
            loupe.radius = CGFloat(c.radius ?? 0)
            return loupe
        case "stamp":     return StampElement(center: c.center ?? .zero, emoji: c.text ?? "⭐️", style: style)
        case "image":
            guard let data = c.imagePNG, let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cg = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let start = c.start, let end = c.end else { return nil }
            let frame = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                               width: abs(end.x - start.x), height: abs(end.y - start.y))
            return ImageElement(image: cg, frame: frame, style: style)
        default:          return nil
        }
    }
}
