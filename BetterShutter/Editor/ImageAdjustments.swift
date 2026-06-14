import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// Non-destructive photo adjustments layered over the editor's base image. Neutral values are the
/// defaults, so `isIdentity` short-circuits to the original bitmap. Applied live for preview and
/// baked only into the exported/flattened result — the base image itself is never mutated.
nonisolated struct ImageAdjustments: Equatable {
    var brightness: Double = 0     // CIColorControls brightness, 0 = neutral
    var contrast: Double = 1       // 1 = neutral
    var saturation: Double = 1     // 1 = neutral
    var sharpness: Double = 0      // CISharpenLuminance, 0 = none

    var isIdentity: Bool { brightness == 0 && contrast == 1 && saturation == 1 && sharpness == 0 }

    /// Return a new CGImage with the adjustments applied (or the input unchanged when identity).
    func apply(to image: CGImage, ciContext: CIContext) -> CGImage {
        guard !isIdentity else { return image }
        var ci = CIImage(cgImage: image)
        let extent = ci.extent

        let controls = CIFilter.colorControls()
        controls.inputImage = ci
        controls.brightness = Float(brightness)
        controls.contrast = Float(contrast)
        controls.saturation = Float(saturation)
        if let out = controls.outputImage { ci = out }

        if sharpness > 0 {
            let sharpen = CIFilter.sharpenLuminance()
            sharpen.inputImage = ci
            sharpen.sharpness = Float(sharpness)
            if let out = sharpen.outputImage { ci = out }
        }

        return ciContext.createCGImage(ci, from: extent) ?? image
    }
}
