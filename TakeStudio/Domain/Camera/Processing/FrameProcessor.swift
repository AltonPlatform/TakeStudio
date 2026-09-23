import AVFoundation
import CoreImage
import ImageIO
import Metal

@MainActor
protocol FrameProcessorDelegate: AnyObject {
    func frameProcessor(_ processor: FrameProcessor, didUpdateDuration duration: TimeInterval, progress: Double)
    func frameProcessorDidReachDurationLimit(_ processor: FrameProcessor)
}

final class FrameProcessor: NSObject {
    enum ProcessingQuality {
        case full
        case reduced
    }

    weak var delegate: FrameProcessorDelegate?

    let filterEngine = FilterEngine()
    let beautyProcessor = BeautyProcessor()
    let greenScreenProcessor = GreenScreenProcessor()
    let previewRenderer: MetalPreviewRenderer

    private let ciContext: CIContext
    private weak var videoCaptureProcessor: VideoCaptureProcessor?
    private var frameCounter = 0

    // Lightweight FPS telemetry (updated on the video processing queue, no main-thread work).
    private(set) var processingFPS: Double = 0
    private var fpsFrameCount = 0
    private var fpsWindowStart = CFAbsoluteTimeGetCurrent()

    var durationLimit: TimeInterval?
    var faceAwareExposureEnabled = false
    var captureSpeed: CaptureSpeed = .normal
    var processingQuality: ProcessingQuality = .full

    var onFaceDetected: ((CGPoint) -> Void)?

    init(device: MTLDevice) {
        ciContext = CIContext(mtlDevice: device, options: [
            .workingColorSpace: NSNull(),
            .cacheIntermediates: false
        ])
        previewRenderer = MetalPreviewRenderer(device: device, ciContext: ciContext)
        super.init()
        greenScreenProcessor.setRenderContext(ciContext)
        greenScreenProcessor.setPrefersFastSegmentation(false)
        greenScreenProcessor.useSynchronousSegmentation = true
    }

    func bindVideoCaptureProcessor(_ processor: VideoCaptureProcessor) {
        videoCaptureProcessor = processor
        processor.ciContext = ciContext
    }

    /// Called on the video output queue when the active camera input changes.
    func prepareForCameraInputChange() {
        greenScreenProcessor.reset()
        previewRenderer.clearLatestFrame()
    }

    private func handleSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        frameCounter += 1
        let useReducedProcessing = processingQuality == .reduced && frameCounter % 2 != 0

        let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
        let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
        let bufferExtent = CGRect(x: 0, y: 0, width: bufferWidth, height: bufferHeight)

        var image = CIImage(cvPixelBuffer: pixelBuffer)
        if image.extent.width <= 0 || image.extent.height <= 0 { return }
        image = image.cropped(to: bufferExtent)

        if faceAwareExposureEnabled, beautyProcessor.intensity > 0, frameCounter % 15 == 0 {
            beautyProcessor.updateFaceExposurePoint(from: image) { [weak self] point in
                self?.onFaceDetected?(point)
            }
        }

        if !useReducedProcessing {
            if greenScreenProcessor.isEnabled {
                // Full-res compositing only while recording; preview uses half scale to cut buffer memory.
                greenScreenProcessor.outputScale = (videoCaptureProcessor?.recording == true) ? 1.0 : 0.5
                let orientation = Self.exifOrientation(from: sampleBuffer)
                image = greenScreenProcessor.process(image, orientation: orientation)
            } else {
                image = filterEngine.process(image)
                if beautyProcessor.intensity > 0.01 {
                    image = beautyProcessor.process(image)
                }
            }
        }
        image = image.cropped(to: bufferExtent)

        previewRenderer.submit(image)
        recordProcessingFPS()

        guard let videoCaptureProcessor, videoCaptureProcessor.recording else { return }
        videoCaptureProcessor.append(
            pixelBuffer: pixelBuffer,
            processedImage: image,
            at: timestamp
        )

        if frameCounter % 6 == 0 {
            let duration = videoCaptureProcessor.currentDuration
            let progress: Double
            if let limit = durationLimit, limit > 0 {
                progress = min(duration / limit, 1)
                if duration >= limit {
                    notifyDurationLimitReached()
                }
            } else {
                progress = 0
            }
            notifyDurationUpdated(duration: duration, progress: progress)
        }
    }

    private func notifyDurationUpdated(duration: TimeInterval, progress: Double) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.delegate?.frameProcessor(self, didUpdateDuration: duration, progress: progress)
            }
        }
    }

    private func recordProcessingFPS() {
        fpsFrameCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - fpsWindowStart
        guard elapsed >= 1.0 else { return }
        processingFPS = Double(fpsFrameCount) / elapsed
        fpsFrameCount = 0
        fpsWindowStart = now
    }

    private var didNotifyDurationLimit = false

    private func notifyDurationLimitReached() {
        guard !didNotifyDurationLimit else { return }
        didNotifyDurationLimit = true
        // Delegate is @MainActor; hop once when the limit is hit, not per frame.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.delegate?.frameProcessorDidReachDurationLimit(self)
            }
        }
    }

    func resetRecordingState() {
        didNotifyDurationLimit = false
    }

    private static func exifOrientation(from sampleBuffer: CMSampleBuffer) -> CGImagePropertyOrientation {
        if let orientation = CMGetAttachment(
            sampleBuffer,
            key: kCGImagePropertyOrientation,
            attachmentModeOut: nil
        ) as? UInt32,
           let exif = CGImagePropertyOrientation(rawValue: orientation) {
            return exif
        }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]],
           let attachment = attachments.first,
           let orientationValue = attachment[kCGImagePropertyOrientation as String] as? UInt32,
           let exif = CGImagePropertyOrientation(rawValue: orientationValue) {
            return exif
        }

        return .up
    }
}

extension FrameProcessor: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        handleSampleBuffer(sampleBuffer)
    }
}
