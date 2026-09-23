import AVFoundation
import Metal

@MainActor
protocol CameraSessionDelegate: AnyObject {
    func cameraSession(_ session: CameraSession, didChangeInterruption interrupted: Bool)
}

final class CameraSession: NSObject, @unchecked Sendable {
    weak var delegate: CameraSessionDelegate?

    let captureSession = AVCaptureSession()
    let deviceManager = CaptureDeviceManager()
    let photoCaptureProcessor = PhotoCaptureProcessor()
    let videoCaptureProcessor = VideoCaptureProcessor()
    let frameProcessor: FrameProcessor

    private let sessionQueue = DispatchQueue(label: "com.alton.camera.session")
    /// Serial queue for Vision segmentation, Core Image compositing, and preview submit.
    private let videoOutputQueue = DispatchQueue(label: "com.alton.camera.processing", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var audioDeviceInput: AVCaptureDeviceInput?

    private(set) var isConfigured = false
    private(set) var isAudioCaptureEnabled = false
    private(set) var quality: VideoQuality = .hd1080p30
    private var lifecycleMonitor: CaptureLifecycleMonitor?

    var zoomStops: [ZoomStop] { deviceManager.zoomStops }
    var zoomFactor: CGFloat { deviceManager.zoomFactor }
    var cameraPosition: AVCaptureDevice.Position { deviceManager.position }
    var hasFlash: Bool { deviceManager.hasFlash }
    var hasTorch: Bool { deviceManager.hasTorch }

    override init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is unavailable on this device.")
        }
        frameProcessor = FrameProcessor(device: device)
        super.init()
        frameProcessor.bindVideoCaptureProcessor(videoCaptureProcessor)
    }

    func configure(enableMicrophone: Bool) async throws {
        let access = await DevicePermissions.requestCaptureAccess(includeMicrophone: enableMicrophone)
        guard access.camera else {
            throw CaptureError.permissionDenied(.camera)
        }

        try await runOnSessionQueue {
            if self.isConfigured {
                if !self.captureSession.isRunning {
                    self.captureSession.startRunning()
                }
                return
            }

            try self.configureSessionLocked(enableMicrophone: enableMicrophone && access.microphone)
            self.isAudioCaptureEnabled = enableMicrophone && access.microphone
                && self.captureSession.outputs.contains(self.audioOutput)

            if self.isAudioCaptureEnabled {
                CameraSessionConfigurator.prepareCaptureAudioRouting(
                    cameraPosition: self.deviceManager.position
                )
            }

            if self.lifecycleMonitor == nil {
                self.lifecycleMonitor = CaptureLifecycleMonitor(
                    session: self.captureSession,
                    sessionQueue: self.sessionQueue,
                    delegate: self
                )
            }

            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
            }
            if self.isAudioCaptureEnabled {
                self.reconfigureAudioInputForStereoCapture()
            }
            self.isConfigured = true
        }
    }

    func startRunning() {
        sessionQueue.async {
            guard self.isConfigured, !self.captureSession.isRunning else { return }
            self.captureSession.startRunning()
        }
    }

    func resumeIfNeeded() {
        sessionQueue.async {
            guard self.isConfigured, !self.captureSession.isRunning else { return }
            self.captureSession.startRunning()
        }
    }

    /// Stops capture and frees GPU buffers without tearing down session configuration.
    func pauseSession() {
        sessionQueue.async {
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
            self.videoOutputQueue.async {
                self.frameProcessor.prepareForCameraInputChange()
                self.frameProcessor.greenScreenProcessor.releaseResources()
            }
        }
    }

    /// Resolves after `captureSession` has stopped (or timeout). Used before presenting Photos UI.
    func waitUntilSessionStopped(timeout: TimeInterval = 1.5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let running: Bool = await withCheckedContinuation { continuation in
                sessionQueue.async {
                    continuation.resume(returning: self.captureSession.isRunning)
                }
            }
            if !running { return }
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    func setAutomaticLifecycleEnabled(_ enabled: Bool) {
        lifecycleMonitor?.automaticSessionControlEnabled = enabled
    }

    func shutdown() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                self.videoCaptureProcessor.cancelRecording()
                self.videoOutput.setSampleBufferDelegate(nil, queue: nil)
                self.audioOutput.setSampleBufferDelegate(nil, queue: nil)
                if self.captureSession.isRunning {
                    self.captureSession.stopRunning()
                }
                self.lifecycleMonitor = nil
                self.isConfigured = false
                self.isAudioCaptureEnabled = false
                self.videoOutputQueue.async {
                    self.frameProcessor.prepareForCameraInputChange()
                    self.frameProcessor.greenScreenProcessor.releaseResources()
                    continuation.resume()
                }
            }
        }
    }

    func flipCamera(enableMicrophone: Bool) async throws {
        try await runOnSessionQueue {
            self.captureSession.beginConfiguration()
            defer { self.captureSession.commitConfiguration() }

            let newPosition: AVCaptureDevice.Position = self.deviceManager.position == .front ? .back : .front
            try self.replaceVideoInput(position: newPosition)
            try? self.deviceManager.setZoomFactor(1.0, rampRate: 0)
            self.updateConnections()
            // Reset frame pipeline on the video queue to avoid stale masks / frozen preview.
            self.videoOutputQueue.sync {
                self.frameProcessor.prepareForCameraInputChange()
            }
            self.deviceManager.scheduleAutoExposureAndWhiteBalanceLock()
            self.reconfigureAudioInputForStereoCapture(for: newPosition)
        }
    }

    func setQuality(_ newQuality: VideoQuality) async throws {
        try await runOnSessionQueue {
            guard self.quality != newQuality else { return }
            self.quality = newQuality
            self.captureSession.beginConfiguration()
            defer { self.captureSession.commitConfiguration() }

            if self.captureSession.canSetSessionPreset(newQuality.sessionPreset) {
                self.captureSession.sessionPreset = newQuality.sessionPreset
            }
            try? self.deviceManager.setFrameRate(newQuality.frameRate, session: self.captureSession)
        }
    }

    func setZoomFactor(_ factor: CGFloat) {
        sessionQueue.async {
            try? self.deviceManager.setZoomFactor(factor)
        }
    }

    func focus(at normalizedPoint: CGPoint, lock: Bool) {
        sessionQueue.async {
            try? self.deviceManager.setFocus(at: normalizedPoint, lock: lock)
        }
    }

    func setExposureBias(_ bias: Float) {
        sessionQueue.async {
            try? self.deviceManager.setExposureBias(bias)
        }
    }

    func resetExposureBias() {
        try? deviceManager.resetExposureBias()
    }

    func setTorchEnabled(_ enabled: Bool) {
        sessionQueue.async {
            try? self.deviceManager.setTorchEnabled(enabled)
        }
    }

    func setCaptureSpeed(_ speed: CaptureSpeed) async throws {
        let baseRate = quality.frameRate
        let targetRate: Int32
        switch speed {
        case .quarter:
            targetRate = min(deviceManager.maxSupportedFrameRate(), max(baseRate * 4, 60))
        case .half:
            targetRate = min(deviceManager.maxSupportedFrameRate(), max(baseRate * 2, 60))
        case .normal, .double, .quadruple:
            targetRate = baseRate
        }

        try await runOnSessionQueue {
            self.frameProcessor.captureSpeed = speed
            self.frameProcessor.processingQuality = speed.requiresHighFrameProcessing ? .reduced : .full
            self.videoCaptureProcessor.captureSpeed = speed
            try self.deviceManager.setFrameRate(targetRate, session: self.captureSession)
        }
    }

    func capturePhoto(flashMode: CameraFlashMode) async throws -> URL {
        try await photoCaptureProcessor.capture(
            flashMode: flashMode,
            mirrored: deviceManager.position == .front
        )
    }

    func startRecording(flashMode: CameraFlashMode) async throws {
        let writerAudioSettings: [String: Any]?
        if isAudioCaptureEnabled {
            writerAudioSettings = try await runOnSessionQueue {
                CameraSessionConfigurator.prepareForVideoRecording(
                    cameraPosition: self.deviceManager.position
                )
                self.reconfigureAudioInputForStereoCapture()
                let forceStereo = self.isHardwareStereoCaptureEnabled
                return CameraSessionConfigurator.writerAudioSettings(
                    from: self.audioOutput,
                    forceStereo: forceStereo
                )
            }
        } else {
            writerAudioSettings = nil
        }

        videoCaptureProcessor.recordsAudio = isAudioCaptureEnabled
        try await videoCaptureProcessor.startRecording(
            quality: quality,
            orientation: CaptureOrientationManager.cachedVideoOrientation(),
            audioSettings: writerAudioSettings
        )
        if flashMode == .on {
            setTorchEnabled(true)
        }
    }

    func warmUpRecording() {
        videoCaptureProcessor.warmUp(
            quality: quality,
            orientation: CaptureOrientationManager.cachedVideoOrientation()
        )
    }

    func finishRecording(resumeCaptureAfterFinish: Bool = true) async throws -> URL {
        let url = try await videoCaptureProcessor.finishRecording()
        setTorchEnabled(false)
        if resumeCaptureAfterFinish {
            resumeIfNeeded()
        }
        return url
    }

    /// Fully releases capture hardware and audio session before editor playback.
    func releaseCaptureForEditor() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                self.captureSession.automaticallyConfiguresApplicationAudioSession = false
                self.videoOutput.setSampleBufferDelegate(nil, queue: nil)
                self.audioOutput.setSampleBufferDelegate(nil, queue: nil)
                if self.captureSession.isRunning {
                    self.captureSession.stopRunning()
                }
                self.videoOutputQueue.async {
                    self.frameProcessor.prepareForCameraInputChange()
                    self.frameProcessor.greenScreenProcessor.releaseResources()
                    continuation.resume()
                }
            }
        }
        try? await Task.sleep(for: .milliseconds(250))
        CameraSessionConfigurator.deactivateCaptureAudioSession()
        try? CameraSessionConfigurator.handoffToPlayback()
    }

    func restoreCaptureAfterEditor() async {
        await runOnSessionQueueVoid {
            guard self.isConfigured else { return }
            self.captureSession.automaticallyConfiguresApplicationAudioSession = true
            CameraSessionConfigurator.configureVideoOutput(self.videoOutput)
            self.videoOutput.setSampleBufferDelegate(self.frameProcessor, queue: self.videoOutputQueue)
            if self.isAudioCaptureEnabled {
                try? CameraSessionConfigurator.configureCaptureAudioSession(
                    cameraPosition: self.deviceManager.position
                )
                self.reconfigureAudioInputForStereoCapture()
                CameraSessionConfigurator.configureAudioOutput(
                    self.audioOutput,
                    delegate: self,
                    queue: self.videoCaptureProcessor.writerQueue
                )
            }
            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
            }
        }
    }

    /// Stops live capture while the editor or playback UI owns GPU/audio resources.
    func pauseCaptureForEditor() {
        Task { await self.releaseCaptureForEditor() }
    }

    func cancelRecording() {
        videoCaptureProcessor.cancelRecording()
        setTorchEnabled(false)
    }

    private func configureSessionLocked(enableMicrophone: Bool) throws {
        captureSession.automaticallyConfiguresApplicationAudioSession = true
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        if captureSession.canSetSessionPreset(quality.sessionPreset) {
            captureSession.sessionPreset = quality.sessionPreset
        }

        try replaceVideoInput(position: .back)

        if enableMicrophone {
            configureAudioInput()
        }

        try? deviceManager.setFrameRate(quality.frameRate, session: captureSession)

        CameraSessionConfigurator.configureVideoOutput(videoOutput)
        videoOutput.setSampleBufferDelegate(frameProcessor, queue: videoOutputQueue)

        if !captureSession.outputs.contains(videoOutput), captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }

        if enableMicrophone, !captureSession.outputs.contains(audioOutput) {
            CameraSessionConfigurator.configureAudioOutput(
                audioOutput,
                delegate: self,
                queue: videoCaptureProcessor.writerQueue
            )
            if captureSession.canAddOutput(audioOutput) {
                captureSession.addOutput(audioOutput)
            }
            if let connection = audioOutput.connection(with: .audio) {
                connection.isEnabled = true
            }
        }

        try photoCaptureProcessor.configure(session: captureSession)
        updateConnections()
        deviceManager.scheduleAutoExposureAndWhiteBalanceLock()
    }

    private func replaceVideoInput(position: AVCaptureDevice.Position) throws {
        captureSession.inputs.forEach { input in
            if input.ports.contains(where: { $0.mediaType == .video }) {
                captureSession.removeInput(input)
            }
        }

        guard
            let device = deviceManager.selectDevice(for: position),
            let input = try? AVCaptureDeviceInput(device: device),
            captureSession.canAddInput(input)
        else {
            throw CaptureError.deviceUnavailable
        }
        captureSession.addInput(input)
    }

    private func configureAudioInput() {
        if let existing = audioDeviceInput {
            _ = CameraSessionConfigurator.applyNativeAudioCaptureOptions(to: existing)
            refreshMicrophoneRouting()
            return
        }

        if let existing = captureSession.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first(where: {
            $0.device.hasMediaType(.audio)
        }) {
            audioDeviceInput = existing
            _ = CameraSessionConfigurator.applyNativeAudioCaptureOptions(to: existing)
            refreshMicrophoneRouting()
            return
        }

        guard
            let device = AVCaptureDevice.default(for: .audio),
            let input = try? AVCaptureDeviceInput(device: device),
            captureSession.canAddInput(input)
        else { return }

        captureSession.addInput(input)
        audioDeviceInput = input
        _ = CameraSessionConfigurator.applyNativeAudioCaptureOptions(to: input)
        refreshMicrophoneRouting()
    }

    private var isHardwareStereoCaptureEnabled: Bool {
        guard let audioDeviceInput else { return false }
        return CameraSessionConfigurator.isHardwareStereoCaptureEnabled(on: audioDeviceInput)
    }

    private func reconfigureAudioInputForStereoCapture(for position: AVCaptureDevice.Position? = nil) {
        guard let input = resolveAudioDeviceInput() else { return }
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        _ = CameraSessionConfigurator.applyNativeAudioCaptureOptions(to: input)
        refreshMicrophoneRouting(for: position)
    }

    private func resolveAudioDeviceInput() -> AVCaptureDeviceInput? {
        if let audioDeviceInput {
            return audioDeviceInput
        }
        if let existing = captureSession.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first(where: {
            $0.device.hasMediaType(.audio)
        }) {
            audioDeviceInput = existing
            return existing
        }
        return nil
    }

    private func refreshMicrophoneRouting(for position: AVCaptureDevice.Position? = nil) {
        let cameraPosition = position ?? deviceManager.position
        let stereoSupported = audioDeviceInput?.isMultichannelAudioModeSupported(.stereo) == true
        CameraSessionConfigurator.preferBuiltInMicrophoneForVideoRecording(
            for: cameraPosition,
            hardwareStereoCapture: stereoSupported
        )
    }

    private func updateConnections() {
        let connection = videoOutput.connection(with: .video)
        CameraSessionConfigurator.applyVideoConnectionSettings(
            to: connection,
            mirrored: deviceManager.position == .front
        )
    }

    private func runOnSessionQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runOnSessionQueueVoid(_ work: @escaping () -> Void) async {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                work()
                continuation.resume()
            }
        }
    }
}

extension CameraSession: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        videoCaptureProcessor.appendAudioFromCapture(sampleBuffer)
    }
}

extension CameraSession: CaptureLifecycleMonitorDelegate {
    func captureLifecycleMonitorDidInterruptSession(_ monitor: CaptureLifecycleMonitor) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.cameraSession(self, didChangeInterruption: true)
        }
    }

    func captureLifecycleMonitorDidResumeSession(_ monitor: CaptureLifecycleMonitor) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.cameraSession(self, didChangeInterruption: false)
        }
    }
}
