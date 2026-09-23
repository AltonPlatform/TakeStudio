import AVFoundation
import Foundation
import Speech

enum SubtitleGeneratorError: LocalizedError {
    case permissionDenied
    case recognizerUnavailable
    case exportFailed
    case recognitionFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Speech recognition permission is required."
        case .recognizerUnavailable: return "Speech recognizer is unavailable for this locale."
        case .exportFailed: return "Failed to export audio for transcription."
        case .recognitionFailed: return "Speech recognition failed."
        }
    }
}

final class SubtitleGenerator {
    func generate(for project: EditorProject, locale: Locale = .current) async throws -> SubtitleTrack {
        let granted = await DevicePermissions.requestSpeechRecognitionAccess()
        guard granted else { throw SubtitleGeneratorError.permissionDenied }

        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw SubtitleGeneratorError.recognizerUnavailable
        }

        let audioURL = try await exportCompositeAudio(from: project)
        defer { TemporaryCaptureStore.removeItem(at: audioURL) }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = true

        let transcription = try await transcribe(recognizer: recognizer, request: request)
        let segments = transcription.segments.map { segment in
            SubtitleSegment(
                text: segment.substring,
                timeRange: CMTimeRange(
                    start: CMTime(seconds: segment.timestamp, preferredTimescale: 600),
                    duration: CMTime(seconds: segment.duration, preferredTimescale: 600)
                ),
                words: segment.substringRange.location != NSNotFound ? nil : nil
            )
        }

        return SubtitleTrack(segments: segments, style: .preset(.classic))
    }

    private func transcribe(recognizer: SFSpeechRecognizer, request: SFSpeechURLRecognitionRequest) async throws -> SFTranscription {
        try await withCheckedThrowingContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let result, result.isFinal else { return }
                continuation.resume(returning: result.bestTranscription)
            }
        }
    }

    private func exportCompositeAudio(from project: EditorProject) async throws -> URL {
        let builder = EditorCompositionBuilder()
        let result = try await builder.build(from: project)
        let outputURL = TemporaryCaptureStore.exportURL().deletingPathExtension().appendingPathExtension("m4a")

        guard let exportSession = AVAssetExportSession(asset: result.composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw SubtitleGeneratorError.exportFailed
        }
        try await exportSession.export(to: outputURL, as: .m4a)
        return outputURL
    }
}
