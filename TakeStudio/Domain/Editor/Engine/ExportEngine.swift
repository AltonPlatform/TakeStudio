import AVFoundation
import Foundation

enum ExportEngineError: LocalizedError {
    case exportFailed(String)
    case cancelled
    case invalidRenderSize(CGSize)

    var errorDescription: String? {
        switch self {
        case .exportFailed(let details):
            return "Video export failed: \(details)"
        case .cancelled:
            return "Export was cancelled."
        case .invalidRenderSize(let size):
            return "Invalid export size \(Int(size.width))×\(Int(size.height))."
        }
    }
}

/// Prevents asset-cache eviction while AVAssetExportSession is running.
enum ExportSessionGuard {
    private(set) static var isActive = false

    static func begin() {
        isActive = true
        EditorCompositorContext.exportMode = true
    }

    static func end() {
        isActive = false
        EditorCompositorContext.exportMode = false
    }
}

final class ExportEngine {
    private let builder = EditorCompositionBuilder()

    func export(
        project: EditorProject,
        quality: ExportQuality = .p1080,
        progress: @escaping (Float) -> Void
    ) async throws -> URL {
        if await project.canUseLosslessExport(quality: quality), let clip = project.clips.first {
            if FileManager.default.fileExists(atPath: clip.sourceURL.path) {
                // Reuse the captured/imported file — no duplicate copy and no re-encode.
                // A full FileManager.copyItem previously doubled disk use and, on failure,
                // fell through to HEVCHighestQuality which OOMs on device.
                EditorAVAssetCache.shared.removeAsset(for: clip.sourceURL)
                PipelineLogger.editor.info(
                    "export lossless reuse source=\(clip.sourceURL.lastPathComponent, privacy: .public) quality=\(quality.rawValue, privacy: .public)"
                )
                await MainActor.run { progress(1) }
                PipelineLogger.editor.info("\(PipelineLogger.fileSummary(clip.sourceURL), privacy: .public)")
                return clip.sourceURL
            }
            PipelineLogger.editor.error(
                "lossless source missing path=\(clip.sourceURL.lastPathComponent, privacy: .public) — encoding fallback"
            )
        }

        let needsCompositor = EditorProject.requiresCustomCompositor(for: project, bakeOverlays: true)
        PipelineLogger.editor.info(
            """
            export start clips=\(project.clips.count) duration=\(project.totalDurationSeconds, format: .fixed(precision: 2))s \
            customCompositor=\(needsCompositor) quality=\(quality.rawValue, privacy: .public)
            """
        )

        ExportSessionGuard.begin()
        defer {
            ExportSessionGuard.end()
            EditorCompositorContext.setState(nil)
        }

        let result: EditorCompositionResult
        do {
            // Build at the target export long-edge so transforms match renderSize.
            // Do not overwrite videoComposition.renderSize after the fact — that
            // desyncs layerInstruction / compositor transforms from the canvas.
            result = try await builder.build(
                from: project,
                quality: .export,
                targetLongEdge: quality.maxLongEdge
            )
        } catch {
            PipelineLogger.logError(PipelineLogger.editor, "composition build failed", error: error)
            throw error
        }

        PipelineLogger.editor.info(
            "composition built renderSize=\(Int(result.renderSize.width))×\(Int(result.renderSize.height)) duration=\(result.totalDuration.seconds, format: .fixed(precision: 2))s"
        )

        let outputURL = TemporaryCaptureStore.exportURL()
        let preset = exportPreset(for: quality, needsCompositor: needsCompositor)
        PipelineLogger.editor.info("export preset=\(preset, privacy: .public)")

        guard let exportSession = AVAssetExportSession(
            asset: result.composition,
            presetName: preset
        ) else {
            throw ExportEngineError.exportFailed("could not create AVAssetExportSession preset=\(preset)")
        }

        // Passthrough only when we truly have no video composition to apply.
        if needsCompositor || result.videoComposition != nil {
            exportSession.videoComposition = result.videoComposition
        }
        exportSession.audioMix = result.audioMix
        exportSession.outputFileType = .mp4

        guard result.renderSize.width >= 2, result.renderSize.height >= 2 else {
            throw ExportEngineError.invalidRenderSize(result.renderSize)
        }

        PipelineLogger.editor.info(
            "export session output=\(outputURL.lastPathComponent, privacy: .public) renderSize=\(Int(result.renderSize.width))×\(Int(result.renderSize.height))"
        )

        let progressStates = exportSession.states(updateInterval: 0.1)
        let progressTimer = Task {
            for await state in progressStates {
                if case .exporting(let exportProgress) = state {
                    let value = Float(exportProgress.fractionCompleted)
                    await MainActor.run {
                        progress(value)
                    }
                }
            }
        }

        defer { progressTimer.cancel() }

        do {
            try await exportSession.export(to: outputURL, as: .mp4)
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: outputURL)
            throw ExportEngineError.cancelled
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            PipelineLogger.editor.error(
                "export session failed underlying=\(error.localizedDescription, privacy: .public)"
            )
            throw ExportEngineError.exportFailed(error.localizedDescription)
        }

        progress(1)
        PipelineLogger.editor.info("\(PipelineLogger.fileSummary(outputURL), privacy: .public)")
        return outputURL
    }

    func reverseClip(sourceURL: URL) async throws -> URL {
        try await Self.reverseClipAsync(sourceURL: sourceURL)
    }

    /// Frame-accurate reverse via AVAssetReader → AVAssetWriter.
    /// Reads all video frames, then writes them in reverse order with remapped timestamps.
    /// TODO: Stream reverse write (two-pass or temp file) instead of buffering the entire clip in memory —
    /// long 4K clips can OOM. Current path keeps full-frame arrays for correctness of timestamp remap.
    private static func reverseClipAsync(sourceURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportEngineError.exportFailed("reverse: missing video track")
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let estimatedDataRate = try await videoTrack.load(.estimatedDataRate)
        let width = max(2, Int(naturalSize.width.rounded()) & ~1)
        let height = max(2, Int(naturalSize.height.rounded()) & ~1)
        guard width > 0, height > 0 else {
            throw ExportEngineError.invalidRenderSize(naturalSize)
        }

        let reader = try AVAssetReader(asset: asset)
        let readerSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: readerSettings)
        // Must copy: we retain sample buffers across the full read before writing in reverse.
        videoOutput.alwaysCopiesSampleData = true
        guard reader.canAdd(videoOutput) else {
            throw ExportEngineError.exportFailed("reverse: cannot add video reader output")
        }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMBitDepthKey: 16
            ]
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: audioSettings)
            output.alwaysCopiesSampleData = true
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
            }
        }

        guard reader.startReading() else {
            throw ExportEngineError.exportFailed(reader.error?.localizedDescription ?? "reverse: reader failed")
        }

        var videoSamples: [CMSampleBuffer] = []
        while let sample = videoOutput.copyNextSampleBuffer() {
            videoSamples.append(sample)
        }

        var audioSamples: [CMSampleBuffer] = []
        if let audioOutput {
            while let sample = audioOutput.copyNextSampleBuffer() {
                audioSamples.append(sample)
            }
        }

        if reader.status == .failed {
            throw ExportEngineError.exportFailed(reader.error?.localizedDescription ?? "reverse: reader failed")
        }
        guard !videoSamples.isEmpty else {
            throw ExportEngineError.exportFailed("reverse: no video frames")
        }

        let outputURL = TemporaryCaptureStore.videoURL()
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let bitrate = max(Int(estimatedDataRate), 2_000_000)
        let writerVideoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate
            ]
        ]
        let writerVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: writerVideoSettings)
        writerVideoInput.expectsMediaDataInRealTime = false
        writerVideoInput.transform = preferredTransform

        let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerVideoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )

        guard writer.canAdd(writerVideoInput) else {
            throw ExportEngineError.exportFailed("reverse: cannot add video writer input")
        }
        writer.add(writerVideoInput)

        var writerAudioInput: AVAssetWriterInput?
        if !audioSamples.isEmpty {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44_100,
                AVEncoderBitRateKey: 128_000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                writerAudioInput = input
            }
        }

        guard writer.startWriting() else {
            throw ExportEngineError.exportFailed(writer.error?.localizedDescription ?? "reverse: writer failed")
        }
        writer.startSession(atSourceTime: .zero)

        // Write video frames in reverse using original presentation times (first→last).
        let presentationTimes = videoSamples.map { CMSampleBufferGetPresentationTimeStamp($0) }
        for (index, time) in presentationTimes.enumerated() {
            let sourceSample = videoSamples[videoSamples.count - 1 - index]
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sourceSample) else { continue }
            while !writerVideoInput.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            if !pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: time) {
                throw ExportEngineError.exportFailed(writer.error?.localizedDescription ?? "reverse: append frame failed")
            }
        }
        writerVideoInput.markAsFinished()

        // Reverse audio by rewriting PCM sample buffers with remapped timestamps.
        if let writerAudioInput, !audioSamples.isEmpty {
            let audioTimes = audioSamples.map { CMSampleBufferGetPresentationTimeStamp($0) }
            for (index, time) in audioTimes.enumerated() {
                let sourceSample = audioSamples[audioSamples.count - 1 - index]
                guard let rewritten = Self.copySampleBuffer(sourceSample, withPresentationTime: time) else { continue }
                while !writerAudioInput.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(2))
                }
                if !writerAudioInput.append(rewritten) {
                    throw ExportEngineError.exportFailed(writer.error?.localizedDescription ?? "reverse: append audio failed")
                }
            }
            writerAudioInput.markAsFinished()
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }
        if let finishError = writer.error {
            throw ExportEngineError.exportFailed(finishError.localizedDescription)
        }
        guard writer.status == .completed else {
            throw ExportEngineError.exportFailed("reverse: writer did not complete")
        }
        return outputURL
    }

    private static func copySampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        withPresentationTime newTime: CMTime
    ) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: newTime,
            decodeTimeStamp: .invalid
        )
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &out
        )
        guard status == noErr else { return nil }
        return out
    }

    /// Prefer bounded HEVC 1080p — `HEVCHighestQuality` routinely OOMs on device for long clips.
    private func exportPreset(for quality: ExportQuality, needsCompositor: Bool) -> String {
        _ = needsCompositor
        switch quality {
        case .p480:
            return AVAssetExportPresetHEVC1920x1080
        case .p720, .p1080, .p4K:
            // Cap encode at 1080p HEVC for memory safety on phone.
            return AVAssetExportPresetHEVC1920x1080
        }
    }
}
