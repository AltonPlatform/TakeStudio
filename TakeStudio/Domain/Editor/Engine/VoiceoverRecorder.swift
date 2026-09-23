import AVFoundation
import Foundation

enum VoiceoverRecorderError: LocalizedError {
    case permissionDenied
    case engineFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Microphone permission is required for voiceover."
        case .engineFailed: return "Voiceover recording failed."
        }
    }
}

@MainActor
@Observable
final class VoiceoverRecorder {
    private(set) var isRecording = false
    private(set) var recordedURL: URL?
    private(set) var levels: [Float] = []

    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private var recordingURL: URL?

    func startRecording() async throws {
        let granted = await DevicePermissions.requestMicrophoneAccess()
        guard granted else { throw VoiceoverRecorderError.permissionDenied }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .videoRecording,
            options: [.defaultToSpeaker, .mixWithOthers]
        )
        try session.setPreferredSampleRate(CameraSessionConfigurator.recordingSampleRate)
        try session.setActive(true)

        let audioEngine = AVAudioEngine()
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        let url = TemporaryCaptureStore.voiceoverURL()
        recordingURL = url

        do {
            file = try AVAudioFile(forWriting: url, settings: format.settings)
        } catch {
            throw VoiceoverRecorderError.engineFailed
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let file = self.file else { return }
            try? file.write(from: buffer)
            let level = Self.level(from: buffer)
            Task { @MainActor in
                self.levels.append(level)
                if self.levels.count > 60 { self.levels.removeFirst() }
            }
        }

        try audioEngine.start()
        engine = audioEngine
        isRecording = true
        recordedURL = nil
        levels = []
    }

    func stopRecording() -> URL? {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        file = nil
        isRecording = false
        let url = recordingURL
        recordingURL = nil
        recordedURL = url
        return url
    }

    /// Clears recorder state without deleting the file (e.g. after it was added to the project).
    func releaseRecordedFileReference() {
        recordedURL = nil
        recordingURL = nil
    }

    func reset() {
        if let url = recordedURL {
            TemporaryCaptureStore.removeIfManaged(url)
        }
        recordedURL = nil
        recordingURL = nil
        isRecording = false
        levels = []
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        file = nil
    }

    private static func level(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<frameLength {
            sum += abs(channelData[index])
        }
        return min(sum / Float(frameLength) * 8, 1)
    }
}
