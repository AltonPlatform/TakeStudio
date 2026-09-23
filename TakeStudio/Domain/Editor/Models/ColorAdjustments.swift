import Foundation

/// Normalized color adjustments in the range -1...1 (except exposure uses -2...2 internally mapped).
struct ColorAdjustments: Equatable, Sendable {
    var brightness: Float
    var contrast: Float
    var saturation: Float
    var warmth: Float
    var exposure: Float
    var sharpness: Float
    var vignette: Float

    init(
        brightness: Float = 0,
        contrast: Float = 0,
        saturation: Float = 0,
        warmth: Float = 0,
        exposure: Float = 0,
        sharpness: Float = 0,
        vignette: Float = 0
    ) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.warmth = warmth
        self.exposure = exposure
        self.sharpness = sharpness
        self.vignette = vignette
    }

    static let identity = ColorAdjustments()

    var isIdentity: Bool {
        brightness == 0
            && contrast == 0
            && saturation == 0
            && warmth == 0
            && exposure == 0
            && sharpness == 0
            && vignette == 0
    }
}
