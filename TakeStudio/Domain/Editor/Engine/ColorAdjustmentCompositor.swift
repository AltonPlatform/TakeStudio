import CoreImage
import Foundation

enum ColorAdjustmentCompositor {
    static func apply(
        to image: CIImage,
        global: ColorAdjustments,
        clip: ColorAdjustments
    ) -> CIImage {
        var result = image
        result = applyAdjustments(global, to: result)
        result = applyAdjustments(clip, to: result)
        return result
    }

    private static func applyAdjustments(_ adjustments: ColorAdjustments, to image: CIImage) -> CIImage {
        guard !adjustments.isIdentity else { return image }

        var result = image

        if adjustments.exposure != 0,
           let filter = CIFilter(name: "CIExposureAdjust") {
            filter.setValue(result, forKey: kCIInputImageKey)
            filter.setValue(adjustments.exposure * 2, forKey: kCIInputEVKey)
            result = filter.outputImage ?? result
        }

        if adjustments.brightness != 0 || adjustments.contrast != 0 || adjustments.saturation != 0,
           let filter = CIFilter(name: "CIColorControls") {
            filter.setValue(result, forKey: kCIInputImageKey)
            filter.setValue(adjustments.brightness, forKey: kCIInputBrightnessKey)
            filter.setValue(1 + adjustments.contrast, forKey: kCIInputContrastKey)
            filter.setValue(1 + adjustments.saturation, forKey: kCIInputSaturationKey)
            result = filter.outputImage ?? result
        }

        if adjustments.warmth != 0,
           let filter = CIFilter(name: "CITemperatureAndTint") {
            filter.setValue(result, forKey: kCIInputImageKey)
            filter.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            let target = 6500 + Double(adjustments.warmth) * 2500
            filter.setValue(CIVector(x: target, y: 0), forKey: "inputTargetNeutral")
            result = filter.outputImage ?? result
        }

        if adjustments.sharpness > 0,
           let filter = CIFilter(name: "CISharpenLuminance") {
            filter.setValue(result, forKey: kCIInputImageKey)
            filter.setValue(adjustments.sharpness * 1.5, forKey: kCIInputSharpnessKey)
            result = filter.outputImage ?? result
        }

        if adjustments.vignette > 0,
           let filter = CIFilter(name: "CIVignette") {
            filter.setValue(result, forKey: kCIInputImageKey)
            filter.setValue(adjustments.vignette * 2, forKey: kCIInputIntensityKey)
            filter.setValue(1.2, forKey: kCIInputRadiusKey)
            result = filter.outputImage ?? result
        }

        return result
    }
}
