import AVFoundation
import Foundation
import UIKit

struct PlaybackRebuildOptions {
    var skipPreroll = false
    var skipStabilityWait = false
    var preferDirectAsset = false
}

@MainActor
final class EditorPlaybackEngine {
    private(set) var player: AVPlayer
    private let builder = EditorCompositionBuilder()
    private var rebuildTask: Task<Void, Never>?
    private var rebuildGeneration: UInt64 = 0
    /// Track-ID → clip-ID map from the last successful composition build (for live audio-mix updates).
    private var lastClipAudioTrackIDs: [CMPersistentTrackID: UUID] = [:]

    /// Shown over the preview surface while swapping `currentItem` to avoid a black flash.
    var onHoldFrameChange: ((UIImage?) -> Void)?
    var onBuildError: ((Error?) -> Void)?

    init() {
        player = AVPlayer()
        player.actionAtItemEnd = .pause
    }

    func rebuild(from project: EditorProject, seekTo time: CMTime? = nil, options: PlaybackRebuildOptions = PlaybackRebuildOptions()) {
        rebuildTask?.cancel()
        rebuildGeneration &+= 1
        let generation = rebuildGeneration
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            await self?.performRebuild(from: project, seekTo: time, generation: generation, options: options)
        }
    }

    func rebuildImmediately(
        from project: EditorProject,
        seekTo time: CMTime? = nil,
        options: PlaybackRebuildOptions = PlaybackRebuildOptions()
    ) async {
        rebuildTask?.cancel()
        rebuildGeneration &+= 1
        let generation = rebuildGeneration
        await performRebuild(from: project, seekTo: time, generation: generation, options: options)
    }

    /// Invalidates in-flight rebuilds so a timed-out bootstrap cannot later replace the current item.
    func invalidatePendingRebuilds() {
        rebuildTask?.cancel()
        rebuildGeneration &+= 1
        onHoldFrameChange?(nil)
    }

    func loadDirectPreview(url: URL, seekTo time: CMTime = .zero) async {
        rebuildTask?.cancel()
        rebuildGeneration &+= 1
        let generation = rebuildGeneration
        player.pause()
        player.isMuted = false
        player.volume = 1.0
        let asset = EditorAVAssetCache.shared.asset(for: url)
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .spectral
        player.replaceCurrentItem(with: item)
        _ = await seekAccurate(to: time)
        guard generation == rebuildGeneration else { return }
        onBuildError?(nil)
    }

    func updateAudioMix(from project: EditorProject) {
        guard let item = player.currentItem,
              let composition = item.asset as? AVComposition else { return }
        item.audioMix = builder.makeAudioMix(
            composition: composition,
            project: project,
            clipAudioTrackIDs: lastClipAudioTrackIDs
        )
    }

    func seek(to time: CMTime) {
        Task {
            await seekAccurate(to: time)
        }
    }

    @discardableResult
    func seekAccurate(to time: CMTime) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            final class Box: @unchecked Sendable {
                var didResume = false
                var timeoutTask: Task<Void, Never>?
                let lock = NSLock()
                func resume(_ value: Bool, continuation: CheckedContinuation<Bool, Never>) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !didResume else { return }
                    didResume = true
                    timeoutTask?.cancel()
                    timeoutTask = nil
                    continuation.resume(returning: value)
                }
            }
            let box = Box()
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                box.resume(finished, continuation: continuation)
            }
            box.timeoutTask = Task {
                try? await Task.sleep(for: .seconds(2))
                box.resume(false, continuation: continuation)
            }
        }
    }

    func play() {
        let duration = player.currentItem?.duration ?? .zero
        if duration.isValid, !duration.isIndefinite,
           player.currentTime() >= duration - CMTime(seconds: 0.05, preferredTimescale: 600) {
            player.seek(to: .zero)
        }
        player.play()
    }

    func pause() {
        player.pause()
    }

    var isPlaying: Bool {
        player.rate > 0
    }

    /// Drops the current item so Fig/XPC is idle before the system keyboard appears.
    func detachPreviewItem() {
        rebuildTask?.cancel()
        rebuildGeneration &+= 1
        player.pause()
        player.replaceCurrentItem(with: nil)
        EditorCompositorContext.setState(nil)
    }

    /// Replaces `AVPlayer` so no Fig playback session remains while the keyboard is up.
    func abandonPlayer() {
        detachPreviewItem()
        player = AVPlayer()
        player.actionAtItemEnd = .pause
    }

    /// Cancels pending rebuilds and detaches the current item so export can own
    /// `EditorCompositorContext` without racing the preview compositor.
    func suspendForExport() {
        rebuildTask?.cancel()
        rebuildGeneration &+= 1
        onHoldFrameChange?(nil)
        player.pause()
        player.replaceCurrentItem(with: nil)
        EditorCompositorContext.setState(nil)
        lastClipAudioTrackIDs = [:]
    }

    func cleanup() {
        suspendForExport()
    }

    private func performRebuild(
        from project: EditorProject,
        seekTo time: CMTime?,
        generation: UInt64,
        options: PlaybackRebuildOptions = PlaybackRebuildOptions()
    ) async {
        let preservedTime = time ?? player.currentTime()
        let wasPlaying = isPlaying

        // Direct preview only when the view model explicitly opts in — never auto-fallback,
        // which previously ignored tail trim / mute / volume / extra audio tracks.
        if options.preferDirectAsset,
           project.canUseDirectPreviewPlayback(),
           project.clips.count == 1,
           let url = project.clips.first?.sourceURL {
            await loadDirectPreview(url: url, seekTo: preservedTime)
            if wasPlaying { player.play() }
            onBuildError?(nil)
            return
        }

        // Split/trim: skip AVAssetImageGenerator — it hitches and is unused
        // once we keep the current frame until the new item is ready.
        // Never attach the same AVPlayerItem to a second AVPlayer: that
        // throws NSInvalidArgumentException and crashes on Split.
        if !options.skipStabilityWait, player.currentItem != nil {
            if let holdFrame = await captureHoldFrameFromCurrentItem() {
                onHoldFrameChange?(holdFrame)
            }
        }

        do {
            let builder = self.builder
            let snapshot = project.snapshot()
            let result = try await Task.detached(priority: .userInitiated) {
                let isolated = EditorProject(snapshot: snapshot)
                return try await builder.build(from: isolated, quality: .preview, bakeOverlays: false)
            }.value
            guard generation == rebuildGeneration else { return }

            lastClipAudioTrackIDs = result.clipAudioTrackIDs

            let item = AVPlayerItem(asset: result.composition)
            item.videoComposition = result.videoComposition
            item.audioMix = result.audioMix
            item.audioTimePitchAlgorithm = .spectral

            player.replaceCurrentItem(with: item)

            let clamped = CMTimeMinimum(preservedTime, result.totalDuration)
            _ = await seekAccurate(to: clamped)
            guard generation == rebuildGeneration else { return }

            let readyTimeout: TimeInterval = options.skipStabilityWait ? 0.8 : 4.0
            var ready = await waitUntilReadyToPlay(item, timeout: readyTimeout)
            guard generation == rebuildGeneration else { return }

            if item.status == .failed || item.error != nil {
                let error = item.error
                    ?? NSError(
                        domain: "EditorPlaybackEngine",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Preview composition failed after rebuild"]
                    )
                onBuildError?(error)
                onHoldFrameChange?(nil)
                return
            }

            if !options.skipStabilityWait {
                if !ready {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard generation == rebuildGeneration else { return }
                    ready = await waitUntilReadyToPlay(item, timeout: 2)
                }
                guard generation == rebuildGeneration else { return }
                if ready {
                    _ = await waitForPlaybackStability(item)
                }
                guard generation == rebuildGeneration else { return }
                if item.status == .failed {
                    onBuildError?(item.error)
                    onHoldFrameChange?(nil)
                    return
                }
            }

            if !options.skipPreroll {
                await prerollIfNeeded(timeout: 2.0)
            }

            guard generation == rebuildGeneration else { return }

            if item.status == .failed || item.error != nil {
                onBuildError?(item.error)
                onHoldFrameChange?(nil)
                return
            }

            onBuildError?(nil)
            if ready || item.status == .readyToPlay {
                onHoldFrameChange?(nil)
            } else {
                // Keep covering the swap until the first decoded frame arrives.
                Task { await self.clearHoldWhenReady(item, generation: generation) }
            }

            if wasPlaying {
                player.play()
            }
        } catch {
            guard generation == rebuildGeneration else { return }
            onBuildError?(error)
            onHoldFrameChange?(nil)
            if project.clips.count == 1, let url = project.clips.first?.sourceURL {
                await loadDirectPreview(url: url, seekTo: preservedTime)
                if wasPlaying { player.play() }
            }
        }
    }

    private func prerollIfNeeded(timeout: TimeInterval = 2.0) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    self.player.preroll(atRate: 1.0) { _ in
                        continuation.resume()
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
            }
            await group.next()
            group.cancelAll()
        }
    }

    private func captureHoldFrameFromCurrentItem() async -> UIImage? {
        guard let item = player.currentItem else { return nil }
        // AVAssetImageGenerator frequently hangs forever when the item uses a custom compositor.
        if item.videoComposition?.customVideoCompositorClass != nil {
            return nil
        }
        let time = player.currentTime()
        guard time.isValid, !time.isIndefinite else { return nil }
        return await generateStill(
            from: item.asset,
            at: time,
            videoComposition: item.videoComposition,
            timeout: 1.5
        )
    }

    private func generateStill(
        from asset: AVAsset,
        at time: CMTime,
        videoComposition: AVVideoComposition?,
        timeout: TimeInterval
    ) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 1280)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.12, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.12, preferredTimescale: 600)
        generator.videoComposition = videoComposition

        return await withCheckedContinuation { continuation in
            final class Box: @unchecked Sendable {
                var didResume = false
                var timeoutTask: Task<Void, Never>?
                let lock = NSLock()
                func resume(_ image: UIImage?, continuation: CheckedContinuation<UIImage?, Never>) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !didResume else { return }
                    didResume = true
                    timeoutTask?.cancel()
                    timeoutTask = nil
                    continuation.resume(returning: image)
                }
            }
            let box = Box()
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, result, _ in
                if result == .succeeded, let cgImage {
                    box.resume(UIImage(cgImage: cgImage), continuation: continuation)
                } else {
                    box.resume(nil, continuation: continuation)
                }
            }
            box.timeoutTask = Task {
                try? await Task.sleep(for: .seconds(timeout))
                generator.cancelAllCGImageGeneration()
                box.resume(nil, continuation: continuation)
            }
        }
    }

    private func clearHoldWhenReady(_ item: AVPlayerItem, generation: UInt64) async {
        _ = await waitUntilReadyToPlay(item, timeout: 3)
        guard generation == rebuildGeneration else { return }
        if item.status == .failed {
            onBuildError?(item.error)
        }
        onHoldFrameChange?(nil)
    }

    /// Returns `false` when the item failed so callers can surface `onBuildError` instead of playing.
    @discardableResult
    private func waitForPlaybackStability(_ item: AVPlayerItem) async -> Bool {
        let ready = await waitUntilReadyToPlay(item, timeout: 4)
        guard ready else { return false }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.waitUntilLikelyToKeepUp(item)
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(800))
            }
            await group.next()
            group.cancelAll()
        }
        return item.status != .failed
    }

    /// Waits until the item is ready. Returns `false` on `.failed` or timeout.
    /// Resumes from any thread — never `await MainActor.run` while holding a continuation
    /// (that deadlocks when this method is called on the main actor).
    private func waitUntilReadyToPlay(_ item: AVPlayerItem, timeout: TimeInterval = 4) async -> Bool {
        if item.status == .readyToPlay { return true }
        if item.status == .failed { return false }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            final class ResumeBox: @unchecked Sendable {
                var didResume = false
                var observation: NSKeyValueObservation?
                var timeoutTask: Task<Void, Never>?
                let lock = NSLock()

                func resume(_ value: Bool, continuation: CheckedContinuation<Bool, Never>) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !didResume else { return }
                    didResume = true
                    observation?.invalidate()
                    observation = nil
                    timeoutTask?.cancel()
                    timeoutTask = nil
                    continuation.resume(returning: value)
                }
            }

            let box = ResumeBox()
            box.observation = item.observe(\.status, options: [.initial, .new]) { observedItem, _ in
                switch observedItem.status {
                case .readyToPlay:
                    box.resume(true, continuation: continuation)
                case .failed:
                    box.resume(false, continuation: continuation)
                default:
                    break
                }
            }

            box.timeoutTask = Task {
                try? await Task.sleep(for: .seconds(timeout))
                box.resume(item.status == .readyToPlay, continuation: continuation)
            }
        }
    }

    private func waitUntilLikelyToKeepUp(_ item: AVPlayerItem) async {
        if item.isPlaybackLikelyToKeepUp { return }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    final class Box: @unchecked Sendable {
                        var didResume = false
                        var observation: NSKeyValueObservation?
                        let lock = NSLock()
                        func resume(_ continuation: CheckedContinuation<Void, Never>) {
                            lock.lock()
                            defer { lock.unlock() }
                            guard !didResume else { return }
                            didResume = true
                            observation?.invalidate()
                            observation = nil
                            continuation.resume()
                        }
                    }
                    let box = Box()
                    box.observation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.initial, .new]) { observed, _ in
                        if observed.isPlaybackLikelyToKeepUp {
                            box.resume(continuation)
                        }
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(800))
            }
            await group.next()
            group.cancelAll()
        }
    }
}

/// Source-clip stills for the text composer. Must not run on the main actor —
/// `AVAssetImageGenerator` + MainActor continuation deadlocks the editor.
enum EditorStillCapture {
    static func image(from project: EditorProject, at time: TimeInterval) async -> UIImage? {
        let compositionTime = CMTime(seconds: time, preferredTimescale: 600)
        guard let clip = project.clip(at: compositionTime) ?? project.clips.last else { return nil }
        let elapsed = max(0, time - clip.compositionStartTime.seconds)
        let sourceSeconds = clip.timeRange.start.seconds + elapsed * max(clip.speed, 0.01)
        let rangeStart = clip.timeRange.start.seconds
        let rangeEnd = max(rangeStart, clip.timeRange.endTime.seconds - 0.02)
        let clamped = min(max(sourceSeconds, rangeStart), rangeEnd)
        let sourceTime = CMTime(seconds: clamped, preferredTimescale: 600)
        let url = clip.sourceURL
        return await Task.detached(priority: .utility) {
            await Self.generate(url: url, at: sourceTime, timeout: 1.0)
        }.value
    }

    private static func generate(url: URL, at time: CMTime, timeout: TimeInterval) async -> UIImage? {
        // Never reuse the playback cache — ImageGenerator + live player on the
        // same AVURLAsset deadlocks Fig (`XPC connection interrupted`).
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let scale = await MainActor.run { CGFloat(UIScreen.main.scale) }
        let native = await MainActor.run { UIScreen.main.nativeBounds.size }
        generator.maximumSize = CGSize(
            width: max(native.width, 1080),
            height: max(native.height, 1920)
        )
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.12, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.12, preferredTimescale: 600)

        return await withCheckedContinuation { continuation in
            final class Box: @unchecked Sendable {
                var didResume = false
                var timeoutTask: Task<Void, Never>?
                let lock = NSLock()
                func resume(_ image: UIImage?, continuation: CheckedContinuation<UIImage?, Never>) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !didResume else { return }
                    didResume = true
                    timeoutTask?.cancel()
                    timeoutTask = nil
                    continuation.resume(returning: image)
                }
            }
            let box = Box()
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, result, _ in
                if result == .succeeded, let cgImage {
                    box.resume(UIImage(cgImage: cgImage, scale: scale, orientation: .up), continuation: continuation)
                } else {
                    box.resume(nil, continuation: continuation)
                }
            }
            box.timeoutTask = Task.detached {
                try? await Task.sleep(for: .seconds(timeout))
                generator.cancelAllCGImageGeneration()
                box.resume(nil, continuation: continuation)
            }
        }
    }
}
