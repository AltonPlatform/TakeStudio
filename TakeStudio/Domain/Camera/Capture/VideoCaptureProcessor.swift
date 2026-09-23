import AVFoundation
import CoreImage
import CoreVideo
import os
import VideoToolbox

final class VideoCaptureProcessor: @unchecked Sendable {
    private static let deviceRGB = CGColorSpaceCreateDeviceRGB()
    let writerQueue = DispatchQueue(label: "com.alton.camera.writer")
    private let recordingState = OSAllocatedUnfairLock(initialState: false)
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var recordingStartTime: CMTime?
    private var lastTimestamp: CMTime = .zero
    private var appendedFrameCount = 0
    private var appendedAudioSampleCount = 0
    private var firstVideoSourceTimestamp: CMTime?
    private var sessionStartSourceTime: CMTime?
    /// Anchor for shifting pre-roll audio that arrived before the writer session started.
    private var preRollAudioAnchor: CMTime?
    private var writerAudioSettings: [String: Any]?
    private var pendingAudioBuffers: [CMSampleBuffer] = []
    private let maxPendingAudioBuffers = 240
    private var loggedFirstAudioBuffer = false
    private let pendingFrameCount = OSAllocatedUnfairLock(initialState: 0)
    private let maxPendingWriterFrames = 3

    var captureSpeed: CaptureSpeed = .normal
    var recordsAudio = true
    var ciContext: CIContext?
    var currentDuration: TimeInterval {
        writerQueue.sync {
            guard let start = recordingStartTime else { return 0 }
            let delta = CMTimeSubtract(lastTimestamp, start)
            return max(0, delta.seconds)
        }
    }

    var recording: Bool {
        recordingState.withLock { $0 }
    }

    private func setRecording(_ isRecording: Bool) {
        recordingState.withLock { $0 = isRecording }
    }

    func startRecording(
        quality: VideoQuality,
        orientation: CaptureVideoOrientation,
        audioSettings: [String: Any]? = nil
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            writerQueue.async {
                do {
                    try self.startRecordingOnWriterQueue(
                        quality: quality,
                        orientation: orientation,
                        audioSettings: audioSettings
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func warmUp(quality: VideoQuality, orientation: CaptureVideoOrientation) {
        writerQueue.async {
            guard !self.recording, self.assetWriter == nil else { return }
            let url = TemporaryCaptureStore.videoURL()
            defer { TemporaryCaptureStore.removeItem(at: url) }
            do {
                let savedRecordsAudio = self.recordsAudio
                self.recordsAudio = false
                try self.configureWriter(at: url, quality: quality, orientation: orientation)
                self.recordsAudio = savedRecordsAudio
                self.assetWriter?.startWriting()
            } catch {
                return
            }
            self.resetWriterState()
        }
    }

    private func startRecordingOnWriterQueue(
        quality: VideoQuality,
        orientation: CaptureVideoOrientation,
        audioSettings: [String: Any]?
    ) throws {
        let url = TemporaryCaptureStore.videoURL()
        try configureWriter(
            at: url,
            quality: quality,
            orientation: orientation,
            audioSettings: audioSettings
        )
        guard let writer = assetWriter else {
            throw CaptureError.recordingFailed
        }
        guard writer.startWriting() else {
            throw writer.error ?? CaptureError.recordingFailed
        }
        setRecording(true)
        sessionStarted = false
        recordingStartTime = nil
        firstVideoSourceTimestamp = nil
        sessionStartSourceTime = nil
        preRollAudioAnchor = nil
        pendingAudioBuffers.removeAll(keepingCapacity: true)
        lastTimestamp = .zero
        appendedFrameCount = 0
        appendedAudioSampleCount = 0
    }

    /// Maps capture timestamps to writer timeline. Uses one anchor for both A/V (Apple pattern).
    private func outputPresentationTime(for sourceTimestamp: CMTime) -> CMTime {
        guard let sessionStartSourceTime else { return sourceTimestamp }

        if captureSpeed == .normal {
            return sourceTimestamp
        }

        let elapsed = CMTimeSubtract(sourceTimestamp, sessionStartSourceTime)
        let scaled = CMTimeMultiplyByFloat64(elapsed, multiplier: 1.0 / captureSpeed.rawValue)
        return CMTimeAdd(sessionStartSourceTime, scaled)
    }

    private func clampedPresentationTime(_ timestamp: CMTime) -> CMTime {
        guard let sessionStartSourceTime, CMTimeCompare(timestamp, sessionStartSourceTime) < 0 else {
            return timestamp
        }
        return sessionStartSourceTime
    }

    private func beginWriterSessionIfNeeded(at sourceTimestamp: CMTime) {
        guard !sessionStarted else { return }

        sessionStartSourceTime = sourceTimestamp
        firstVideoSourceTimestamp = sourceTimestamp
        assetWriter?.startSession(atSourceTime: sourceTimestamp)
        recordingStartTime = sourceTimestamp
        sessionStarted = true
        flushPendingAudioBuffers()
    }

    func append(pixelBuffer: CVPixelBuffer, processedImage: CIImage, at timestamp: CMTime) {
        // Drop frames before enqueueing so writerQueue can't accumulate CIImages unboundedly.
        let accepted = pendingFrameCount.withLock { count -> Bool in
            guard count < self.maxPendingWriterFrames else { return false }
            count += 1
            return true
        }
        guard accepted else { return }

        writerQueue.async {
            defer {
                self.pendingFrameCount.withLock { $0 = max(0, $0 - 1) }
            }
            guard self.recording else { return }
            guard
                let writer = self.assetWriter,
                let adaptor = self.pixelBufferAdaptor,
                let videoInput = self.videoInput
            else { return }

            guard writer.status == .writing else { return }

            if !self.sessionStarted {
                self.beginWriterSessionIfNeeded(at: timestamp)
            }

            let presentationTime = self.clampedPresentationTime(
                self.outputPresentationTime(for: timestamp)
            )

            guard videoInput.isReadyForMoreMediaData else { return }
            guard let pool = adaptor.pixelBufferPool else { return }

            var destination: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination)
            guard status == kCVReturnSuccess, let outputBuffer = destination else { return }

            if !self.render(processedImage, sourceBuffer: pixelBuffer, into: outputBuffer) {
                return
            }

            guard adaptor.append(outputBuffer, withPresentationTime: presentationTime) else { return }

            self.lastTimestamp = presentationTime
            self.appendedFrameCount += 1
            self.flushPendingAudioBuffers()
        }
    }

    /// Called on `writerQueue` from `AVCaptureAudioDataOutput`. Appends directly — no async PCM copy.
    func appendAudioFromCapture(_ sampleBuffer: CMSampleBuffer) {
        guard recording, recordsAudio else { return }
        guard let writer = assetWriter, writer.status == .writing else { return }

        if !loggedFirstAudioBuffer {
            loggedFirstAudioBuffer = true
            CameraSessionConfigurator.logPCMSampleBuffer(sampleBuffer, context: "firstCaptureBuffer")
        }

        guard audioInput != nil else { return }

        if !sessionStarted {
            guard let copied = sampleBuffer.deepCopyPCM() else { return }
            enqueuePendingAudio(copied)
            return
        }

        appendAudioSampleBuffer(sampleBuffer)
        flushPendingAudioBuffers()
    }

    private func enqueuePendingAudio(_ sampleBuffer: CMSampleBuffer) {
        guard pendingAudioBuffers.count < maxPendingAudioBuffers else { return }
        pendingAudioBuffers.append(sampleBuffer)
    }

    private func flushPendingAudioBuffers() {
        guard sessionStarted, let audioInput, audioInput.isReadyForMoreMediaData else { return }
        while audioInput.isReadyForMoreMediaData, !pendingAudioBuffers.isEmpty {
            let buffer = pendingAudioBuffers.removeFirst()
            appendAudioSampleBuffer(buffer)
        }
    }

    private func presentationTimeForAudio(_ rawTimestamp: CMTime, sessionStart: CMTime) -> CMTime {
        if CMTimeCompare(rawTimestamp, sessionStart) < 0 {
            if preRollAudioAnchor == nil {
                preRollAudioAnchor = rawTimestamp
            }
            let delta = CMTimeSubtract(rawTimestamp, preRollAudioAnchor!)
            return CMTimeAdd(sessionStart, delta)
        }

        preRollAudioAnchor = nil
        if captureSpeed == .normal {
            return rawTimestamp
        }
        return outputPresentationTime(for: rawTimestamp)
    }

    private func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let audioInput, let sessionStartSourceTime else { return }

        let rawTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard rawTimestamp.isValid else { return }

        let presentationTime = presentationTimeForAudio(rawTimestamp, sessionStart: sessionStartSourceTime)

        if !audioInput.isReadyForMoreMediaData {
            if let copied = sampleBuffer.deepCopyPCM() {
                enqueuePendingAudio(copied)
            }
            return
        }

        if captureSpeed == .normal, CMTimeCompare(presentationTime, rawTimestamp) == 0 {
            guard audioInput.append(sampleBuffer) else {
                let message = assetWriter?.error?.localizedDescription ?? "unknown"
                Self.logger.error("audio append failed (direct): \(message, privacy: .public)")
                return
            }
        } else {
            guard let retimedBuffer = sampleBuffer.retimed(to: presentationTime) else { return }
            guard audioInput.append(retimedBuffer) else {
                let message = assetWriter?.error?.localizedDescription ?? "unknown"
                Self.logger.error("audio append failed (retimed): \(message, privacy: .public)")
                return
            }
        }

        appendedAudioSampleCount += 1
    }

    func finishRecording() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            writerQueue.async {
                self.finishRecordingOnWriterQueue(continuation: continuation)
            }
        }
    }

    func cancelRecording() {
        writerQueue.async {
            self.cancelRecordingOnWriterQueue()
        }
    }

    private func render(
        _ processedImage: CIImage,
        sourceBuffer: CVPixelBuffer,
        into destination: CVPixelBuffer
    ) -> Bool {
        let width = CVPixelBufferGetWidth(destination)
        let height = CVPixelBufferGetHeight(destination)
        guard width > 0, height > 0 else { return false }

        let sourceWidth = CVPixelBufferGetWidth(sourceBuffer)
        let sourceHeight = CVPixelBufferGetHeight(sourceBuffer)
        let targetExtent = CGRect(x: 0, y: 0, width: width, height: height)

        if let context = ciContext {
            let image = orientedImageForWriting(
                processedImage,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                destinationWidth: width,
                destinationHeight: height
            )
            let sourceExtent = image.extent.integral
            guard sourceExtent.width > 0, sourceExtent.height > 0 else {
                return copyPixelBuffer(from: sourceBuffer, to: destination)
            }

            if sourceExtent.size == targetExtent.size {
                CVPixelBufferLockBaseAddress(destination, [])
                defer { CVPixelBufferUnlockBaseAddress(destination, []) }
                context.render(
                    image,
                    to: destination,
                    bounds: targetExtent,
                    colorSpace: Self.deviceRGB
                )
                return true
            }

            let scale = max(
                targetExtent.width / sourceExtent.width,
                targetExtent.height / sourceExtent.height
            )
            let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let originX = (targetExtent.width - scaled.extent.width) / 2 - scaled.extent.origin.x
            let originY = (targetExtent.height - scaled.extent.height) / 2 - scaled.extent.origin.y
            let fitted = scaled
                .transformed(by: CGAffineTransform(translationX: originX, y: originY))
                .cropped(to: targetExtent)

            CVPixelBufferLockBaseAddress(destination, [])
            defer { CVPixelBufferUnlockBaseAddress(destination, []) }

            context.render(
                fitted,
                to: destination,
                bounds: targetExtent,
                colorSpace: Self.deviceRGB
            )
            return true
        }

        return copyPixelBuffer(from: sourceBuffer, to: destination)
    }

    private func copyPixelBuffer(from source: CVPixelBuffer, to destination: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(destination, [])
        }

        guard
            CVPixelBufferGetWidth(source) == CVPixelBufferGetWidth(destination),
            CVPixelBufferGetHeight(source) == CVPixelBufferGetHeight(destination),
            let sourceBase = CVPixelBufferGetBaseAddress(source),
            let destBase = CVPixelBufferGetBaseAddress(destination)
        else { return false }

        let bytesPerRow = min(CVPixelBufferGetBytesPerRow(source), CVPixelBufferGetBytesPerRow(destination))
        let height = CVPixelBufferGetHeight(source)
        for row in 0..<height {
            let src = sourceBase.advanced(by: row * CVPixelBufferGetBytesPerRow(source))
            let dst = destBase.advanced(by: row * CVPixelBufferGetBytesPerRow(destination))
            memcpy(dst, src, bytesPerRow)
        }
        return true
    }

    private func finishRecordingOnWriterQueue(continuation: CheckedContinuation<URL, Error>) {
        defer {
            resetWriterState()
            setRecording(false)
        }

        guard let writer = assetWriter else {
            continuation.resume(throwing: CaptureError.recordingFailed)
            return
        }

        let outputURL = writer.outputURL

        guard sessionStarted, appendedFrameCount > 0, writer.status == .writing else {
            writer.cancelWriting()
            TemporaryCaptureStore.removeItem(at: outputURL)
            continuation.resume(throwing: CaptureError.recordingTooShort)
            return
        }

        flushPendingAudioBuffers()

        videoInput?.markAsFinished()
        if recordsAudio {
            audioInput?.markAsFinished()
        }

        writer.finishWriting {
            if writer.status == .completed {
                continuation.resume(returning: outputURL)
            } else {
                TemporaryCaptureStore.removeItem(at: outputURL)
                continuation.resume(throwing: writer.error ?? CaptureError.recordingFailed)
            }
        }
    }

    private func cancelRecordingOnWriterQueue() {
        defer {
            resetWriterState()
            setRecording(false)
        }

        guard let writer = assetWriter else { return }

        let outputURL = writer.outputURL

        switch writer.status {
        case .writing:
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            writer.cancelWriting()
        case .unknown:
            writer.cancelWriting()
        default:
            break
        }

        TemporaryCaptureStore.removeItem(at: outputURL)
    }

    private func configureWriter(
        at url: URL,
        quality: VideoQuality,
        orientation: CaptureVideoOrientation,
        audioSettings: [String: Any]? = nil
    ) throws {
        resetWriterState()
        writerAudioSettings = audioSettings

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        // videoRotationAngle on the capture connection already rotates delivered buffers.
        let (width, height) = outputDimensions(for: quality, orientation: orientation)

        // HEVC (hvc1) matches server copy-path when already 1080×1920 yuv420p —
        // avoids a second lossy encode in media-service.
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: quality.bitrate,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
                AVVideoExpectedSourceFrameRateKey: quality.frameRate
            ]
        ]

        let newVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        newVideoInput.expectsMediaDataInRealTime = true
        newVideoInput.transform = .identity

        guard writer.canAdd(newVideoInput) else {
            throw CaptureError.recordingFailed
        }
        writer.add(newVideoInput)

        let sourceAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: newVideoInput,
            sourcePixelBufferAttributes: sourceAttributes
        )

        // All writer inputs must be added before startWriting() — no lazy audio input.
        if recordsAudio, let audioSettings = writerAudioSettings {
            audioInput = makeAudioInput(for: writer, settings: audioSettings, sourceFormatHint: nil)
            if audioInput == nil {
                throw CaptureError.recordingFailed
            }
            Self.logger.debug("AVAssetWriter audio input added before startWriting")
        }

        assetWriter = writer
        videoInput = newVideoInput
    }

    private func resetWriterState() {
        assetWriter = nil
        videoInput = nil
        pixelBufferAdaptor = nil
        audioInput = nil
        sessionStarted = false
        recordingStartTime = nil
        firstVideoSourceTimestamp = nil
        sessionStartSourceTime = nil
        preRollAudioAnchor = nil
        pendingAudioBuffers.removeAll()
        writerAudioSettings = nil
        lastTimestamp = .zero
        appendedFrameCount = 0
        appendedAudioSampleCount = 0
        loggedFirstAudioBuffer = false
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.alton.app",
        category: "VideoCaptureProcessor"
    )

    private func makeAudioInput(
        for writer: AVAssetWriter,
        settings: [String: Any],
        sourceFormatHint: CMAudioFormatDescription?
    ) -> AVAssetWriterInput? {
        let input: AVAssetWriterInput
        if let sourceFormatHint {
            input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: settings,
                sourceFormatHint: sourceFormatHint
            )
        } else {
            input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        }
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        return input
    }

    private func orientedImageForWriting(
        _ image: CIImage,
        sourceWidth: Int,
        sourceHeight: Int,
        destinationWidth: Int,
        destinationHeight: Int
    ) -> CIImage {
        let sourceLandscape = sourceWidth > sourceHeight
        let destinationPortrait = destinationHeight > destinationWidth

        guard sourceLandscape, destinationPortrait else { return image }

        let rotated = image
            .transformed(by: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(sourceHeight), ty: 0))
        return rotated.cropped(to: CGRect(x: 0, y: 0, width: destinationWidth, height: destinationHeight))
    }

    private func outputDimensions(
        for quality: VideoQuality,
        orientation: CaptureVideoOrientation
    ) -> (width: Int, height: Int) {
        switch orientation {
        case .portrait, .portraitUpsideDown:
            return (quality.outputWidth, quality.outputHeight)
        case .landscapeRight, .landscapeLeft:
            return (quality.outputHeight, quality.outputWidth)
        }
    }
}
