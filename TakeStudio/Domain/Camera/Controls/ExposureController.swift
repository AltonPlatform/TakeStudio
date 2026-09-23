import AVFoundation

struct ExposureController {
    var bias: Float = 0
    var minBias: Float = -3
    var maxBias: Float = 3

    mutating func syncLimits(from deviceManager: CaptureDeviceManager) {
        minBias = deviceManager.minExposureBias
        maxBias = deviceManager.maxExposureBias
    }

    func clampedBias(_ value: Float) -> Float {
        min(max(value, minBias), maxBias)
    }
}
