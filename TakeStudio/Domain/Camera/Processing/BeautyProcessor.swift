import CoreImage
import Vision

final class BeautyProcessor {
    private let visionQueue = DispatchQueue(label: "com.alton.camera.beauty.vision")
    private var cachedMask: CIImage?
    private var frameCounter = 0
    private let throttleInterval = 3

    var intensity: Double = 0

    func process(_ image: CIImage) -> CIImage {
        guard intensity > 0.01 else { return image }

        frameCounter += 1
        if frameCounter % throttleInterval == 0 {
            updateMask(for: image)
        }

        guard let mask = cachedMask else { return image }
        let amount = CGFloat(intensity)

        guard let blur = CIFilter(name: "CIGaussianBlur") else { return image }
        blur.setValue(image, forKey: kCIInputImageKey)
        blur.setValue(2 + amount * 2, forKey: kCIInputRadiusKey)
        guard let blurred = blur.outputImage?.cropped(to: image.extent) else { return image }

        guard let tone = CIFilter(name: "CIColorControls") else { return image }
        tone.setValue(blurred, forKey: kCIInputImageKey)
        tone.setValue(0.05 * amount, forKey: kCIInputBrightnessKey)
        tone.setValue(-0.05 * amount, forKey: kCIInputContrastKey)
        guard let toned = tone.outputImage else { return image }

        guard let glow = CIFilter(name: "CIHighlightShadowAdjust") else { return image }
        glow.setValue(toned, forKey: kCIInputImageKey)
        glow.setValue(0.15 * amount, forKey: "inputHighlightAmount")
        glow.setValue(0.1 * amount, forKey: "inputShadowAmount")
        guard let enhanced = glow.outputImage else { return image }

        guard let blend = CIFilter(name: "CIBlendWithMask") else { return image }
        blend.setValue(enhanced, forKey: kCIInputImageKey)
        blend.setValue(image, forKey: kCIInputBackgroundImageKey)
        blend.setValue(mask, forKey: kCIInputMaskImageKey)
        return blend.outputImage ?? image
    }

    func updateFaceExposurePoint(from image: CIImage, completion: @escaping (CGPoint) -> Void) {
        visionQueue.async {
            let request = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(ciImage: image, options: [:])
            try? handler.perform([request])
            guard let face = request.results?.first else { return }
            let box = face.boundingBox
            completion(CGPoint(x: box.midX, y: box.midY))
        }
    }

    private func updateMask(for image: CIImage) {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8

        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        visionQueue.async { [weak self] in
            try? handler.perform([request])
            guard let observation = request.results?.first else { return }
            let mask = CIImage(cvPixelBuffer: observation.pixelBuffer)
            self?.cachedMask = mask
        }
    }

    func reset() {
        cachedMask = nil
        frameCounter = 0
    }
}
