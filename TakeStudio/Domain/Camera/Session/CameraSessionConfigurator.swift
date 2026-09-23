import AVFoundation
import os

/// Audio capture tuned to match the system Camera app: `.videoRecording` mode processing,
/// 48 kHz stereo, built-in mic routing, wind noise reduction (iOS 18+).
enum CameraSessionConfigurator {
    static let recordingSampleRate: Double = 48_000
    static let recordingIOBufferDuration: TimeInterval = 0.005
    static let recordingChannelCount = 2
    static let recordingAACBitrate = 256_000

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.alton.app",
        category: "CameraAudio"
    )

    private static let captureCategoryOptions: AVAudioSession.CategoryOptions = [
        .defaultToSpeaker,
        .allowBluetoothHFP
    ]

    // MARK: - AVAudioSession

    /// Mic routing + soft 48 kHz preference while `AVCaptureSession` manages category/mode.
    static func prepareCaptureAudioRouting(cameraPosition: AVCaptureDevice.Position) {
        preferBuiltInMicrophoneForVideoRecording(for: cameraPosition)
        applyRecordingPreferencesSoft(context: "prepareCaptureAudioRouting")
        logAudioSessionState("prepareCaptureAudioRouting")
    }

    /// Reclaim capture routing after editor playback. Only used when capture session is stopped.
    static func configureCaptureAudioSession(cameraPosition: AVCaptureDevice.Position = .back) throws {
        let audioSession = AVAudioSession.sharedInstance()
        try setCaptureCategory(on: audioSession)
        try audioSession.setActive(true)
        preferBuiltInMicrophoneForVideoRecording(for: cameraPosition)
        applyRecordingPreferencesSoft(context: "configureCaptureAudioSession")
        logAudioSessionState("configureCaptureAudioSession")
    }

    static func configureAudioSession(cameraPosition: AVCaptureDevice.Position = .back) throws {
        try configureCaptureAudioSession(cameraPosition: cameraPosition)
    }

    /// Call on the session queue immediately before `AVAssetWriter` starts.
    static func prepareForVideoRecording(cameraPosition: AVCaptureDevice.Position) {
        preferBuiltInMicrophoneForVideoRecording(for: cameraPosition)
        applyRecordingPreferencesSoft(context: "prepareForVideoRecording")
        logAudioSessionState("prepareForVideoRecording")
    }

    static func configureRecordingSampleRate() {
        applyRecordingPreferencesSoft(context: "configureRecordingSampleRate")
    }

    static func prepareAutomaticCaptureAudioSession() {
        applyRecordingPreferencesSoft(context: "prepareAutomaticCaptureAudioSession")
    }

    static func configurePlaybackAudioSession() throws {
        try handoffToPlayback()
    }

    static func deactivateCaptureAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        logAudioSessionState("deactivateCaptureAudioSession")
    }

    static func handoffToPlayback() throws {
        let audioSession = AVAudioSession.sharedInstance()
        // Soft transitions — hard setActive(false/true) can hang for a long time on Simulator.
        try? audioSession.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try? audioSession.setActive(true, options: [])
        logAudioSessionState("handoffToPlayback")
    }

    // MARK: - Session preferences

    private static func setCaptureCategory(on audioSession: AVAudioSession) throws {
        try audioSession.setCategory(
            .playAndRecord,
            mode: .videoRecording,
            options: captureCategoryOptions
        )
    }

    /// Never throws — invalid preferences (e.g. input channel count) must not block capture.
    private static func applyRecordingPreferencesSoft(context: String) {
        let audioSession = AVAudioSession.sharedInstance()

        if let error = attempt({ try audioSession.setPreferredSampleRate(recordingSampleRate) }) {
            logger.warning("[\(context, privacy: .public)] setPreferredSampleRate failed: \(error.localizedDescription, privacy: .public)")
        }
        if let error = attempt({ try audioSession.setPreferredIOBufferDuration(recordingIOBufferDuration) }) {
            logger.warning("[\(context, privacy: .public)] setPreferredIOBufferDuration failed: \(error.localizedDescription, privacy: .public)")
        }
        if let error = attempt({ try audioSession.setPreferredOutputNumberOfChannels(recordingChannelCount) }) {
            logger.warning("[\(context, privacy: .public)] setPreferredOutputNumberOfChannels failed: \(error.localizedDescription, privacy: .public)")
        }

        let rate = audioSession.sampleRate
        if !isRecordingSampleRate(rate) {
            logger.debug(
                "[\(context, privacy: .public)] hardware sampleRate=\(rate, privacy: .public)Hz (preferred \(recordingSampleRate, privacy: .public)Hz; converges when capture runs)"
            )
        }
    }

    private static func attempt(_ work: () throws -> Void) -> Error? {
        do {
            try work()
            return nil
        } catch {
            return error
        }
    }

    private static func isRecordingSampleRate(_ rate: Double) -> Bool {
        abs(rate - recordingSampleRate) < 1
    }

    static func logAudioSessionState(_ context: String) {
        let session = AVAudioSession.sharedInstance()
        let inputChannels = session.inputNumberOfChannels
        let outputChannels = session.outputNumberOfChannels
        let inputName = session.currentRoute.inputs.first?.portName ?? "none"
        logger.debug(
            "[\(context, privacy: .public)] category=\(session.category.rawValue, privacy: .public) mode=\(session.mode.rawValue, privacy: .public) rate=\(session.sampleRate, privacy: .public)Hz inCh=\(inputChannels, privacy: .public) outCh=\(outputChannels, privacy: .public) input=\(inputName, privacy: .public)"
        )
    }

    static func logPCMSampleBuffer(_ sampleBuffer: CMSampleBuffer, context: String) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        else {
            logger.warning("[\(context, privacy: .public)] unable to read PCM format")
            return
        }
        logger.debug(
            "[\(context, privacy: .public)] PCM rate=\(asbd.mSampleRate, privacy: .public)Hz ch=\(asbd.mChannelsPerFrame, privacy: .public) bits=\(asbd.mBitsPerChannel, privacy: .public) frames=\(CMSampleBufferGetNumSamples(sampleBuffer), privacy: .public)"
        )
        if Int(asbd.mChannelsPerFrame) < recordingChannelCount {
            logger.warning(
                "[\(context, privacy: .public)] expected \(recordingChannelCount, privacy: .public)ch stereo PCM, got \(asbd.mChannelsPerFrame, privacy: .public)ch"
            )
        }
    }

    // MARK: - AVCaptureDeviceInput (iOS 18+)

    static func applyNativeAudioCaptureOptions(to input: AVCaptureDeviceInput) -> Bool {
        guard input.device.hasMediaType(.audio) else { return false }

        var stereoActive = false
        if input.isMultichannelAudioModeSupported(.stereo) {
            input.multichannelAudioMode = .stereo
            stereoActive = input.multichannelAudioMode == .stereo
            logger.debug(
                "multichannelAudioMode=stereo active=\(stereoActive, privacy: .public) windNoise=\(input.isWindNoiseRemovalEnabled, privacy: .public)"
            )
        } else {
            logger.warning("hardware stereo multichannel not supported on audio input")
        }

        if input.isWindNoiseRemovalSupported {
            input.isWindNoiseRemovalEnabled = true
        }

        return stereoActive
    }

    static func isHardwareStereoCaptureEnabled(on input: AVCaptureDeviceInput) -> Bool {
        input.isMultichannelAudioModeSupported(.stereo) && input.multichannelAudioMode == .stereo
    }

    // MARK: - Built-in microphone routing

    /// Picks the mic data source nearest the active camera and aligns stereo orientation with video.
    /// When hardware stereo (`multichannelAudioMode`) is active, skips polar-pattern overrides.
    static func preferBuiltInMicrophoneForVideoRecording(
        for cameraPosition: AVCaptureDevice.Position,
        hardwareStereoCapture: Bool = true
    ) {
        let audioSession = AVAudioSession.sharedInstance()
        guard
            let builtInPort = audioSession.availableInputs?
                .first(where: { $0.portType == .builtInMic })
        else { return }

        try? audioSession.setPreferredInput(builtInPort)

        guard let dataSources = builtInPort.dataSources, !dataSources.isEmpty else { return }

        let preferredOrientation: AVAudioSession.Orientation =
            cameraPosition == .front ? .front : .bottom
        let dataSource =
            dataSources.first(where: { $0.orientation == preferredOrientation })
            ?? dataSources.first(where: { $0.orientation == .bottom })
            ?? dataSources.first

        guard let dataSource else { return }
        try? builtInPort.setPreferredDataSource(dataSource)

        if !hardwareStereoCapture, let patterns = dataSource.supportedPolarPatterns {
            let pattern: AVAudioSession.PolarPattern? = {
                if patterns.contains(.subcardioid) { return .subcardioid }
                if patterns.contains(.cardioid) { return .cardioid }
                return nil
            }()
            if let pattern {
                try? dataSource.setPreferredPolarPattern(pattern)
            }
        }

        try? audioSession.setPreferredInputOrientation(
            CaptureOrientationManager.cachedStereoInputOrientation()
        )
    }

    // MARK: - AVAssetWriter audio

    static func writerAudioSettings(
        from audioOutput: AVCaptureAudioDataOutput,
        fileType: AVFileType = .mp4,
        forceStereo: Bool = false
    ) -> [String: Any] {
        let base = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: fileType)
            ?? fallbackWriterAudioSettings()
        let normalized = normalizedNativeRecordingAudioSettings(base, forceStereo: forceStereo)
        logWriterAudioSettings(normalized, source: "recommendedAudioSettingsForAssetWriter")
        return normalized
    }

    static func fallbackWriterAudioSettings() -> [String: Any] {
        normalizedNativeRecordingAudioSettings([
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: recordingSampleRate,
            AVNumberOfChannelsKey: recordingChannelCount,
            AVEncoderBitRateKey: recordingAACBitrate
        ])
    }

    /// Keeps Apple's recommended encoder keys, forces 48 kHz, resolves bitrate-key conflicts.
    static func normalizedNativeRecordingAudioSettings(
        _ base: [String: Any],
        forceStereo: Bool = false
    ) -> [String: Any] {
        var settings = base
        settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
        settings[AVSampleRateKey] = recordingSampleRate
        if forceStereo {
            settings[AVNumberOfChannelsKey] = recordingChannelCount
        } else if settings[AVNumberOfChannelsKey] == nil {
            settings[AVNumberOfChannelsKey] = recordingChannelCount
        }

        let hasPerChannel = settings[AVEncoderBitRatePerChannelKey] != nil
        let hasTotal = settings[AVEncoderBitRateKey] != nil

        if hasPerChannel && hasTotal {
            settings.removeValue(forKey: AVEncoderBitRateKey)
        } else if !hasPerChannel && !hasTotal {
            settings[AVEncoderBitRateKey] = recordingAACBitrate
        }

        settings.removeValue(forKey: AVEncoderAudioQualityKey)

        return settings
    }

    private static func logWriterAudioSettings(_ settings: [String: Any], source: String) {
        let rate: Double = {
            if let value = settings[AVSampleRateKey] as? Double { return value }
            if let value = settings[AVSampleRateKey] as? Int { return Double(value) }
            if let value = settings[AVSampleRateKey] as? NSNumber { return value.doubleValue }
            return 0
        }()
        let channels = settings[AVNumberOfChannelsKey] as? Int ?? 0
        let bitrate = settings[AVEncoderBitRateKey] as? Int ?? settings[AVEncoderBitRatePerChannelKey] as? Int ?? 0
        logger.debug(
            "[\(source, privacy: .public)] AAC rate=\(rate, privacy: .public)Hz ch=\(channels, privacy: .public) bitrate=\(bitrate, privacy: .public)"
        )
    }

    // MARK: - Capture outputs

    static func configureAudioOutput(
        _ output: AVCaptureAudioDataOutput,
        delegate: AVCaptureAudioDataOutputSampleBufferDelegate,
        queue: DispatchQueue
    ) {
        output.setSampleBufferDelegate(delegate, queue: queue)
    }

    static func configureVideoOutput(_ output: AVCaptureVideoDataOutput) {
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
    }

    static func applyVideoConnectionSettings(to connection: AVCaptureConnection?, mirrored: Bool) {
        CaptureOrientationManager.applyCaptureRotation(to: connection, mirrored: mirrored)
        if connection?.isVideoStabilizationSupported == true {
            connection?.preferredVideoStabilizationMode = .off
        }
    }
}
