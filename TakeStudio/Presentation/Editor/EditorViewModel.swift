import AVFoundation
import Observation
import PhotosUI
import SwiftUI
import UIKit

@MainActor
@Observable
final class EditorViewModel {
    var project: EditorProject
    var selectedTool: EditorTool = .edit
    var selectedClipID: UUID?
    var selectedTextID: UUID?
    var selectedStickerID: UUID?
    var selectedSubtitleID: UUID?
    var selectedAudioTrackID: UUID?
    var currentTime: TimeInterval = 0
    var totalDuration: TimeInterval = 0
    var isExporting = false
    var exportProgress: Float = 0
    var isSavingToGallery = false
    var gallerySaveMessage: String?
    var isPlaying = false
    var errorMessage: String?
    var pixelsPerSecond: CGFloat = 60
    var hasFitTimelineWidth = false
    var isGeneratingSubtitles = false
    var subtitleGenerationProgress: String?
    var showSpeedPanel = false
    var isBootstrapping = true
    var bootstrapProgress: Double = 0
    var bootstrapMessage = "Preparing video…"
    var previewHoldFrame: UIImage?
    var canUndo = false
    var canRedo = false
    var lastUndoActionName: String?
    var showHistorySheet = false
    var pendingToolPresentation: EditorTool?
    /// Requests music picker from `EditorView` (avoids sheet-on-sheet).
    var pendingMusicPicker = false
    /// Requests transition picker from `EditorView`.
    var pendingTransitionClipID: UUID?
    /// Requests clip actions sheet from `EditorView`.
    var pendingClipActionsClipID: UUID?
    var inlineEditingTextID: UUID?
    /// Overlay is created; composer opens after any tool sheet finishes dismissing.
    var pendingTextPromptID: UUID?
    /// TikTok-style caption composer is covering the editor.
    var isTextInputActive = false
    /// Preview has no `AVPlayer` item while text input owns the window.
    var isPreviewDetached = false
    var textComposerDraft = ""
    var textComposerColorHex = "#FFFFFF"
    var textComposerCenter = CGPoint(x: 0.5, y: 0.5)
    var textComposerSnapshot: UIImage?
    /// Composer interaction mode while `isTextInputActive`.
    var composerMode: TextComposerMode = .editing
    /// Selected layer for handles / style panel (may differ from editing ID briefly).
    var composerSelectedID: UUID?
    /// Layer currently owning the shared `UITextView` first responder.
    var composerEditingID: UUID?
    /// When true, playback pauses on composer open (TikTok default).
    var composerPauseVideoOnOpen = true
    /// Debounce gate for rapid add/delete taps.
    private var lastComposerMutationAt: CFAbsoluteTime = 0
    private let composerMutationDebounce: CFAbsoluteTime = 0.2
    private var lastPreviewStill: UIImage?
    private var previewStillTask: Task<UIImage?, Never>?
    private var textComposerOpenTask: Task<Void, Never>?
    private var styleApplyTask: Task<Void, Never>?
    private var styleApplyGeneration: UInt64 = 0
    var colorAdjustTargetIsGlobal = false
    private(set) var isClipTrimming = false
    private(set) var frozenPlayheadTime: TimeInterval?
    private(set) var frozenTotalDuration: TimeInterval?
    private(set) var trimVisualSettleToken: UInt64 = 0
    /// Draft text for inline editing — avoids mutating project.textOverlays on every keystroke.
    private var textOverlayDraft: [UUID: String] = [:]
    private var textCommitTask: Task<Void, Never>?
    private var textCommitGeneration: UInt64 = 0

    var displayCurrentTime: TimeInterval {
        isClipTrimming ? (frozenPlayheadTime ?? currentTime) : currentTime
    }

    var displayTotalDuration: TimeInterval {
        isClipTrimming ? (frozenTotalDuration ?? totalDuration) : totalDuration
    }

    var hasVisibleOverlaysAtPlayhead: Bool {
        let time = currentTime
        let textVisible = project.textOverlays.contains { overlay in
            time >= overlay.timeRange.start.seconds && time <= overlay.timeRange.endSeconds
        }
        let stickerVisible = project.stickerOverlays.contains { overlay in
            time >= overlay.timeRange.start.seconds && time <= overlay.timeRange.endSeconds
        }
        return textVisible || stickerVisible
    }

    var undoHistoryTitles: [String] {
        undoStack.map(\.name).reversed()
    }

    let playbackEngine = EditorPlaybackEngine()
    let voiceoverRecorder = VoiceoverRecorder()
    let waveformStore = WaveformStore()

    private let exportEngine = ExportEngine()
    private let subtitleGenerator = SubtitleGenerator()
    private let maxHistorySteps = 40
    private let maxHistoryBytes = 10 * 1024 * 1024
    private var undoStack: [(name: String, snapshot: EditorProjectSnapshot)] = []
    private var redoStack: [(name: String, snapshot: EditorProjectSnapshot)] = []
    private var undoStackBytes = 0
    private var isApplyingHistory = false
    private var gestureEditRecorded = false
    private var timeObserver: Any?
    private var greenScreenRebuildTask: Task<Void, Never>?
    private var trimPreviewByClipID: [UUID: CMTimeRange] = [:]
    private var trimCommitTask: Task<Void, Never>?
    private var trimGestureGeneration: UInt64 = 0
    private var lastExportURL: URL?
    private var memoryWarningObserver: (any NSObjectProtocol)?
    // Accessed from `nonisolated deinit` — must stay out of Observation tracking.
    @ObservationIgnored private nonisolated(unsafe) var teardownTimeObserver: Any?
    @ObservationIgnored private nonisolated(unsafe) var teardownMemoryObserver: (any NSObjectProtocol)?
    @ObservationIgnored private nonisolated(unsafe) var teardownPlayer: AVPlayer?

    init(project: EditorProject) {
        self.project = project
        selectedClipID = project.clips.first?.id
        playbackEngine.onHoldFrameChange = { [weak self] image in
            self?.previewHoldFrame = image
        }
        playbackEngine.onBuildError = { [weak self] error in
            self?.errorMessage = error?.localizedDescription
        }
        registerMemoryWarningObserver()
        updateHistoryAvailability()
        Task { await bootstrap() }
    }

    convenience init(initialVideoURL: URL) async throws {
        let project = try await EditorProject.fromInitialVideo(url: initialVideoURL)
        self.init(project: project)
    }

    convenience init(clipURLs: [URL]) async throws {
        let project = try await EditorProject.fromClipURLs(clipURLs)
        self.init(project: project)
    }

    func cleanup() {
        if let timeObserver {
            playbackEngine.player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
            teardownTimeObserver = nil
            teardownPlayer = nil
        }
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
            self.memoryWarningObserver = nil
            teardownMemoryObserver = nil
        }
        greenScreenRebuildTask?.cancel()
        greenScreenRebuildTask = nil
        textCommitTask?.cancel()
        textCommitTask = nil
        trimPreviewByClipID.removeAll()
        trimCommitTask?.cancel()
        trimCommitTask = nil
        previewHoldFrame = nil
        isPreviewDetached = false
        lastPreviewStill = nil
        previewStillTask?.cancel()
        previewStillTask = nil
        textComposerOpenTask?.cancel()
        textComposerOpenTask = nil
        styleApplyTask?.cancel()
        styleApplyTask = nil
        TimelineScrollRegistry.reset()
        playbackEngine.cleanup()
        voiceoverRecorder.releaseRecordedFileReference()
        FilmstripExtractionService.shared.clearOnMemoryWarning()
        Task {
            await WaveformGenerator.shared.clearCache()
        }
        EditorAVAssetCache.shared.clearAll()
        waveformStore.clear()
    }

    func purgeUnreferencedTempMedia(keeping additional: Set<URL> = []) {
        var keep = project.referencedMediaURLs()
        keep.formUnion(additional)
        keep.formUnion(historyReferencedMediaURLs())
        if let lastExportURL {
            keep.insert(lastExportURL)
        }
        TemporaryCaptureStore.purgeUnreferenced(keeping: keep)
    }

    nonisolated deinit {
        if let teardownTimeObserver, let teardownPlayer {
            teardownPlayer.removeTimeObserver(teardownTimeObserver)
        }
        if let teardownMemoryObserver {
            NotificationCenter.default.removeObserver(teardownMemoryObserver)
        }
    }

    var player: AVPlayer { playbackEngine.player }

    var selectedClip: VideoClip? {
        get {
            guard let id = selectedClipID else { return project.clips.first }
            return project.clips.first { $0.id == id }
        }
        set {
            guard let newValue, let index = project.clips.firstIndex(where: { $0.id == newValue.id }) else { return }
            performEdit("Update Clip", rebuild: true) {
                project.clips[index] = newValue
            }
        }
    }

    // MARK: - History

    private func historyReferencedMediaURLs() -> Set<URL> {
        var urls = Set<URL>()
        for entry in undoStack {
            urls.formUnion(entry.snapshot.referencedMediaURLs())
        }
        for entry in redoStack {
            urls.formUnion(entry.snapshot.referencedMediaURLs())
        }
        return urls
    }

    private func updateHistoryAvailability() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        lastUndoActionName = undoStack.last?.name
    }

    private func recordHistory(_ name: String) {
        guard !isApplyingHistory else { return }
        let snapshot = project.snapshot()
        let cost = approximateSnapshotCost(snapshot)
        undoStack.append((name, snapshot))
        undoStackBytes += cost
        while undoStack.count > maxHistorySteps || undoStackBytes > maxHistoryBytes, !undoStack.isEmpty {
            let removed = undoStack.removeFirst()
            undoStackBytes = max(0, undoStackBytes - approximateSnapshotCost(removed.snapshot))
        }
        redoStack.removeAll()
        updateHistoryAvailability()
    }

    private func approximateSnapshotCost(_ snapshot: EditorProjectSnapshot) -> Int {
        var cost = snapshot.clips.count * 512
        cost += snapshot.audioTracks.count * 256
        cost += snapshot.textOverlays.reduce(0) { $0 + $1.text.utf8.count + 64 }
        cost += snapshot.stickerOverlays.count * 128
        if let subtitleTrack = snapshot.subtitleTrack {
            cost += subtitleTrack.segments.reduce(0) { $0 + $1.text.utf8.count + 32 }
        }
        return max(cost, 256)
    }

    func performEdit(_ name: String, rebuild: Bool = true, shouldRecordHistory: Bool = true, _ body: () -> Void) {
        if shouldRecordHistory {
            recordHistory(name)
        }
        body()
        project.updateCompositionStartTimes()
        totalDuration = project.totalDurationSeconds
        if rebuild {
            scheduleRebuild()
        }
    }

    func beginGestureEdit(_ name: String) {
        guard !gestureEditRecorded else { return }
        recordHistory(name)
        gestureEditRecorded = true
    }

    func endGestureEdit(rebuild: Bool = true) {
        gestureEditRecorded = false
        project.updateCompositionStartTimes()
        totalDuration = project.totalDurationSeconds
        if rebuild {
            scheduleRebuild()
        }
    }

    func undo() {
        guard let entry = undoStack.popLast() else { return }
        undoStackBytes = max(0, undoStackBytes - approximateSnapshotCost(entry.snapshot))
        isApplyingHistory = true
        defer {
            isApplyingHistory = false
            updateHistoryAvailability()
        }

        redoStack.append((entry.name, project.snapshot()))
        let pipelineBefore = project.playbackPipelineState
        project.restore(from: entry.snapshot)
        validateSelectionsAfterHistoryChange()
        totalDuration = project.totalDurationSeconds
        inlineEditingTextID = nil
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Task {
            await refreshPlaybackAfterHistory(previousPipeline: pipelineBefore)
        }
    }

    func redo() {
        guard let entry = redoStack.popLast() else { return }
        isApplyingHistory = true
        defer {
            isApplyingHistory = false
            updateHistoryAvailability()
        }

        undoStack.append((entry.name, project.snapshot()))
        undoStackBytes += approximateSnapshotCost(undoStack.last!.snapshot)
        while undoStack.count > maxHistorySteps || undoStackBytes > maxHistoryBytes, !undoStack.isEmpty {
            let removed = undoStack.removeFirst()
            undoStackBytes = max(0, undoStackBytes - approximateSnapshotCost(removed.snapshot))
        }
        let pipelineBefore = project.playbackPipelineState
        project.restore(from: entry.snapshot)
        validateSelectionsAfterHistoryChange()
        totalDuration = project.totalDurationSeconds
        inlineEditingTextID = nil
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Task {
            await refreshPlaybackAfterHistory(previousPipeline: pipelineBefore)
        }
    }

    private func refreshPlaybackAfterHistory(
        previousPipeline: EditorPlaybackPipelineState,
        options: PlaybackRebuildOptions = PlaybackRebuildOptions()
    ) async {
        let pipelineAfter = project.playbackPipelineState
        guard pipelineAfter != previousPipeline else { return }

        let seekTime = CMTime(seconds: min(currentTime, totalDuration), preferredTimescale: 600)
        var rebuildOptions = options
        if project.canUseDirectPreviewPlayback() {
            rebuildOptions.preferDirectAsset = true
        }
        await playbackEngine.rebuildImmediately(from: project, seekTo: seekTime, options: rebuildOptions)
    }

    func jumpToHistoryStep(index: Int) {
        guard index >= 0, index < undoStack.count else { return }
        let stepsBack = index + 1
        guard stepsBack <= undoStack.count else { return }

        let pipelineBefore = project.playbackPipelineState
        isApplyingHistory = true
        defer {
            isApplyingHistory = false
            updateHistoryAvailability()
            showHistorySheet = false
        }

        let lastIndex = undoStack.count - 1
        let targetIndex = lastIndex - index
        let targetSnapshot = undoStack[targetIndex].snapshot

        redoStack.append((undoStack[lastIndex].name, project.snapshot()))
        if stepsBack > 1 {
            for i in stride(from: lastIndex - 1, through: targetIndex, by: -1) {
                redoStack.append((undoStack[i].name, undoStack[i + 1].snapshot))
            }
        }

        while undoStack.count > targetIndex {
            let removed = undoStack.removeLast()
            undoStackBytes = max(0, undoStackBytes - approximateSnapshotCost(removed.snapshot))
        }

        project.restore(from: targetSnapshot)
        validateSelectionsAfterHistoryChange()
        totalDuration = project.totalDurationSeconds
        inlineEditingTextID = nil
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Task {
            await refreshPlaybackAfterHistory(
                previousPipeline: pipelineBefore,
                options: PlaybackRebuildOptions(skipPreroll: true, skipStabilityWait: true)
            )
        }
    }

    private func validateSelectionsAfterHistoryChange() {
        if let selectedClipID, !project.clips.contains(where: { $0.id == selectedClipID }) {
            self.selectedClipID = project.clips.first?.id
        }
        if let selectedTextID, !project.textOverlays.contains(where: { $0.id == selectedTextID }) {
            self.selectedTextID = nil
        }
        if let selectedStickerID, !project.stickerOverlays.contains(where: { $0.id == selectedStickerID }) {
            self.selectedStickerID = nil
        }
        if let selectedAudioTrackID, !project.audioTracks.contains(where: { $0.id == selectedAudioTrackID }) {
            self.selectedAudioTrackID = project.audioTracks.first?.id
        }
        if let selectedSubtitleID,
           !(project.subtitleTrack?.segments.contains(where: { $0.id == selectedSubtitleID }) ?? false) {
            self.selectedSubtitleID = nil
        }
    }

    // MARK: - Timeline / playback

    func fitTimelineToWidth(availableWidth: CGFloat) {
        guard !hasFitTimelineWidth, totalDuration > 0, availableWidth > 0 else { return }
        let fitScale = availableWidth / CGFloat(totalDuration)
        pixelsPerSecond = min(max(fitScale, EditorTimelineConstants.minPixelsPerSecond), EditorTimelineConstants.maxPixelsPerSecond)
        hasFitTimelineWidth = true
    }

    func bootstrap() async {
        bootstrapMessage = "Building timeline…"
        bootstrapProgress = 0.35
        project.updateCompositionStartTimes()
        totalDuration = project.totalDurationSeconds

        bootstrapMessage = "Rendering preview…"
        bootstrapProgress = 0.65

        // Waveforms can load after the editor is interactive.
        Task { await loadClipWaveforms() }

        // Preview load must not hang forever (broken seek / audio on simulator).
        await withTimeout(seconds: 4) {
            if self.project.clips.count == 1, let url = self.project.clips.first?.sourceURL {
                await self.playbackEngine.loadDirectPreview(url: url)
            } else {
                await self.playbackEngine.rebuildImmediately(
                    from: self.project,
                    options: PlaybackRebuildOptions(skipPreroll: true, skipStabilityWait: true)
                )
            }
        }

        setupTimeObserver()

        bootstrapProgress = 1
        bootstrapMessage = "Ready"
        isBootstrapping = false
    }

    /// Runs `operation`, but always resumes within `seconds` so bootstrap can't wedge the UI.
    private func withTimeout(seconds: TimeInterval, operation: @escaping @MainActor () async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                await operation()
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
            }
            await group.next()
            group.cancelAll()
            // Do not invalidate the rebuild — let it finish after the spinner goes away.
            // Invalidating here was leaving a black preview with no retry.
        }
    }

    private func loadClipWaveforms() async {
        for clip in project.clips {
            await waveformStore.loadIfNeeded(for: clip.sourceURL)
        }
    }

    func scheduleRebuild(seekTo time: CMTime? = nil) {
        guard !isExporting else { return }
        project.updateCompositionStartTimes()
        totalDuration = project.totalDurationSeconds
        // Skip stability/preroll — waiting on AVPlayer readiness freezes interaction after Split/trim.
        var options = PlaybackRebuildOptions(skipPreroll: true, skipStabilityWait: true)
        if project.canUseDirectPreviewPlayback() {
            options.preferDirectAsset = true
        }
        playbackEngine.rebuild(from: project, seekTo: time, options: options)
    }

    func togglePlayback() {
        if isPlaying {
            pausePlayback()
        } else {
            resumePlayback()
        }
    }

    func pausePlayback() {
        playbackEngine.pause()
        isPlaying = false
    }

    func resumePlayback() {
        if isPreviewDetached {
            reattachPreviewKeepingItem()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                guard !self.isTextInputActive, !self.isPreviewDetached else { return }
                self.playbackEngine.play()
                self.isPlaying = self.playbackEngine.isPlaying
            }
            return
        }
        playbackEngine.play()
        isPlaying = playbackEngine.isPlaying
    }

    func seek(to time: TimeInterval) {
        currentTime = min(max(time, 0), totalDuration)
        playbackEngine.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600))
    }

    func setSpeed(_ speed: Double) {
        guard var clip = selectedClip else { return }
        performEdit("Change Speed") {
            clip.speed = speed
            if let index = project.clips.firstIndex(where: { $0.id == clip.id }) {
                project.clips[index] = clip
            }
        }
    }

    func clipForTimeline(_ clip: VideoClip) -> VideoClip {
        guard let preview = trimPreviewByClipID[clip.id] else { return clip }
        var copy = clip
        copy.timeRange = preview
        return copy
    }

    func timelineClips() -> [VideoClip] {
        project.clips.map { clipForTimeline($0) }
    }

    func beginClipTrim() {
        guard !isClipTrimming else { return }
        trimGestureGeneration &+= 1
        beginGestureEdit("Trim Clip")
        isClipTrimming = true
        frozenPlayheadTime = currentTime
        frozenTotalDuration = totalDuration
    }

    func cancelClipTrim() {
        let generation = trimGestureGeneration
        trimCommitTask?.cancel()
        trimCommitTask = nil
        trimPreviewByClipID.removeAll()

        if gestureEditRecorded {
            if undoStack.last?.name == "Trim Clip" {
                let removed = undoStack.removeLast()
                undoStackBytes = max(0, undoStackBytes - approximateSnapshotCost(removed.snapshot))
            }
            gestureEditRecorded = false
            updateHistoryAvailability()
        }

        endClipTrimVisualFreeze(generation: generation)
    }

    func endClipTrimVisualFreeze(generation: UInt64? = nil) {
        if let generation, generation != trimGestureGeneration { return }
        guard isClipTrimming else { return }
        isClipTrimming = false
        frozenPlayheadTime = nil
        frozenTotalDuration = nil
        trimVisualSettleToken &+= 1
        if gestureEditRecorded {
            endGestureEdit(rebuild: false)
        }
    }

    func previewClipTrim(clipID: UUID, timeRange: CMTimeRange) {
        guard project.clips.contains(where: { $0.id == clipID }) else { return }
        trimPreviewByClipID[clipID] = timeRange
    }

    func commitClipTrim(clipID: UUID, timeRange: CMTimeRange) {
        let generation = trimGestureGeneration
        trimCommitTask?.cancel()
        trimCommitTask = nil

        guard let index = project.clips.firstIndex(where: { $0.id == clipID }) else {
            endClipTrimVisualFreeze(generation: generation)
            trimPreviewByClipID.removeValue(forKey: clipID)
            return
        }

        let previousRange = project.clips[index].timeRange
        let unchanged = CMTimeRangeEqual(previousRange, timeRange)

        project.clips[index].timeRange = timeRange
        trimPreviewByClipID.removeValue(forKey: clipID)
        project.updateCompositionStartTimes()
        totalDuration = project.totalDurationSeconds

        if unchanged {
            endClipTrimVisualFreeze(generation: generation)
            return
        }

        let seekTime = CMTime(seconds: min(currentTime, totalDuration), preferredTimescale: 600)
        trimCommitTask = Task { @MainActor in
            defer {
                // Skip freeze clear when superseded by a newer commit/cancel.
                if !Task.isCancelled {
                    self.endClipTrimVisualFreeze(generation: generation)
                }
            }
            guard !self.isExporting else { return }

            let wasPlaying = self.isPlaying
            if wasPlaying {
                self.playbackEngine.pause()
                self.isPlaying = false
            }

            await self.playbackEngine.rebuildImmediately(
                from: self.project,
                seekTo: seekTime,
                options: PlaybackRebuildOptions(skipPreroll: true, skipStabilityWait: true)
            )

            if wasPlaying, !Task.isCancelled, !self.isExporting {
                self.resumePlayback()
            }
        }
    }

    func splitClip(at time: TimeInterval) async {
        guard
            let clip = selectedClip,
            let index = project.clips.firstIndex(where: { $0.id == clip.id })
        else { return }

        let compositionTime = CMTime(seconds: time, preferredTimescale: 600)
        let localOffset = CMTimeSubtract(compositionTime, clip.compositionStartTime)
        let speed = max(clip.speed, 0.01)
        let sourceOffset = CMTime(seconds: localOffset.seconds / speed, preferredTimescale: 600)
        let splitPoint = CMTimeAdd(clip.timeRange.start, sourceOffset)

        guard CMTimeCompare(sourceOffset, CMTime(seconds: 0.2, preferredTimescale: 600)) > 0,
              CMTimeCompare(CMTimeSubtract(clip.timeRange.endTime, splitPoint), CMTime(seconds: 0.2, preferredTimescale: 600)) > 0
        else { return }

        let seekTime = CMTime(seconds: currentTime, preferredTimescale: 600)

        performEdit("Split Clip", rebuild: false) {
            var first = clip
            first.timeRange = CMTimeRange.from(start: clip.timeRange.start, end: splitPoint)
            // Cut between the two halves — don't leave a transition on the mid-clip join.
            first.transition = .cut
            first.transitionDuration = 0.3

            let second = VideoClip(
                sourceURL: clip.sourceURL,
                timeRange: CMTimeRange.from(start: splitPoint, end: clip.timeRange.endTime),
                sourceTimeRange: clip.sourceTimeRange,
                speed: clip.speed,
                volume: clip.volume,
                isMuted: clip.isMuted,
                filterIDs: clip.filterIDs,
                colorAdjustments: clip.colorAdjustments,
                framing: clip.framing,
                transform: clip.transform,
                hasDetachedAudio: clip.hasDetachedAudio,
                // Preserve the original outgoing transition for whatever follows the second half.
                transition: clip.transition,
                transitionDuration: clip.transitionDuration,
                greenScreenEffect: clip.greenScreenEffect
            )

            project.clips[index] = first
            project.clips.insert(second, at: index + 1)
            selectedClipID = first.id
        }

        // Never await a full stability/preroll rebuild here — that freezes the editor UI.
        // Debounced rebuild keeps the timeline interactive while preview catches up.
        scheduleRebuild(seekTo: seekTime)
        errorMessage = nil
    }

    func reverseSelectedClip() async {
        guard let clip = selectedClip,
              let index = project.clips.firstIndex(where: { $0.id == clip.id }) else { return }
        beginGestureEdit("Reverse Clip")
        do {
            let reversedURL = try await exportEngine.reverseClip(sourceURL: clip.sourceURL)
            let asset = EditorAVAssetCache.shared.asset(for: reversedURL)
            let duration = try await asset.load(.duration)
            let fullRange = CMTimeRange(start: .zero, duration: duration)
            project.clips[index].sourceURL = reversedURL
            project.clips[index].sourceTimeRange = fullRange
            project.clips[index].timeRange = fullRange
            purgeUnreferencedTempMedia()
            project.updateCompositionStartTimes()
            totalDuration = project.totalDurationSeconds
            endGestureEdit(rebuild: false)
            await playbackEngine.rebuildImmediately(
                from: project,
                options: PlaybackRebuildOptions(skipPreroll: true, skipStabilityWait: true)
            )
        } catch {
            if gestureEditRecorded {
                if undoStack.last?.name == "Reverse Clip" {
                    let removed = undoStack.removeLast()
                    undoStackBytes = max(0, undoStackBytes - approximateSnapshotCost(removed.snapshot))
                    updateHistoryAvailability()
                }
                gestureEditRecorded = false
            }
            errorMessage = error.localizedDescription
        }
    }

    func toggleClipMute(clipID: UUID) {
        performEdit("Toggle Mute") {
            guard let index = project.clips.firstIndex(where: { $0.id == clipID }) else { return }
            project.clips[index].isMuted.toggle()
        }
    }

    func detachAudio(from clipID: UUID) {
        performEdit("Detach Audio") {
            guard let index = project.clips.firstIndex(where: { $0.id == clipID }) else { return }
            var clip = project.clips[index]
            guard !clip.hasDetachedAudio else { return }

            clip.hasDetachedAudio = true
            clip.isMuted = true
            project.clips[index] = clip

            let track = AudioTrack(
                sourceURL: clip.sourceURL,
                timeRange: clip.timeRange,
                startTime: clip.compositionStartTime,
                volume: clip.volume,
                isDetachedFromVideo: true,
                kind: .detached,
                title: "Detached Audio"
            )
            project.audioTracks.append(track)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func reattachAudio(trackID: UUID) {
        performEdit("Reattach Audio") {
            guard let trackIndex = project.audioTracks.firstIndex(where: { $0.id == trackID }) else { return }
            let track = project.audioTracks[trackIndex]
            guard track.isDetachedFromVideo || track.kind == .detached else { return }

            if let clipIndex = project.clips.firstIndex(where: { $0.sourceURL == track.sourceURL && $0.hasDetachedAudio }) {
                project.clips[clipIndex].hasDetachedAudio = false
                project.clips[clipIndex].isMuted = false
            }
            project.audioTracks.remove(at: trackIndex)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func deleteAudioTrack(_ trackID: UUID) {
        performEdit("Delete Audio Track") {
            project.audioTracks.removeAll { $0.id == trackID }
            purgeUnreferencedTempMedia()
        }
    }

    func moveClip(from source: Int, to destination: Int) {
        guard source != destination,
              source >= 0, source < project.clips.count,
              destination >= 0, destination <= project.clips.count else { return }
        performEdit("Reorder Clip") {
            let clip = project.clips.remove(at: source)
            let insertIndex = destination > source ? destination - 1 : destination
            project.clips.insert(clip, at: min(max(insertIndex, 0), project.clips.count))
        }
    }

    func moveLayer(from source: Int, to destination: Int) {
        guard source != destination,
              source >= 0, source < project.layerOrder.count,
              destination >= 0, destination < project.layerOrder.count else { return }
        performEdit("Reorder Layer") {
            let layer = project.layerOrder.remove(at: source)
            project.layerOrder.insert(layer, at: destination)
            project.normalizeLayerOrder()
        }
    }

    func previewVoiceoverSegment(_ segment: VoiceoverSegment) {
        guard var track = project.voiceoverTrack,
              let index = track.segments.firstIndex(where: { $0.id == segment.id }) else { return }
        track.segments[index] = segment
        project.voiceoverTrack = track
    }

    func commitVoiceoverSegment(_ segment: VoiceoverSegment) {
        performEdit("Edit Voiceover") {
            previewVoiceoverSegment(segment)
        }
    }

    func deleteClip(_ clipID: UUID) {
        performEdit("Delete Clip") {
            project.clips.removeAll { $0.id == clipID }
            if selectedClipID == clipID {
                selectedClipID = project.clips.first?.id
            }
            purgeUnreferencedTempMedia()
        }
    }

    func setClipVolume(_ volume: Float) {
        guard let clipID = selectedClipID,
              let index = project.clips.firstIndex(where: { $0.id == clipID }) else { return }
        if !gestureEditRecorded {
            beginGestureEdit("Adjust Volume")
        }
        project.clips[index].volume = volume
        project.clips[index].isMuted = volume <= 0
        playbackEngine.updateAudioMix(from: project)
    }

    func commitClipVolumeChange() {
        endGestureEdit(rebuild: false)
    }

    func setClipTransition(_ transition: ClipTransition, duration: Double? = nil, for clipID: UUID? = nil) {
        let targetID = clipID ?? selectedClipID
        // Update model without awaiting a heavy rebuild on the caller's stack.
        performEdit("Set Transition", rebuild: false) {
            guard let targetID,
                  let index = project.clips.firstIndex(where: { $0.id == targetID }) else { return }
            project.clips[index].transition = transition
            if let duration {
                project.clips[index].transitionDuration = duration
            }
        }
        scheduleRebuild(seekTo: CMTime(seconds: currentTime, preferredTimescale: 600))
    }

    func setGreenScreenEffect(_ effect: GreenScreenEffect?, for clipID: UUID? = nil, recordHistory: Bool = true) {
        let targetID = clipID ?? selectedClipID
        guard let targetID,
              let index = project.clips.firstIndex(where: { $0.id == targetID }) else { return }

        if recordHistory {
            performEdit("Green Screen", rebuild: false) {
                project.clips[index].greenScreenEffect = effect
                purgeUnreferencedTempMedia()
            }
        } else {
            if !gestureEditRecorded {
                beginGestureEdit("Green Screen")
            }
            project.clips[index].greenScreenEffect = effect
            purgeUnreferencedTempMedia()
        }
        scheduleGreenScreenRebuild()
    }

    func commitGreenScreenEffectChange() {
        endGestureEdit(rebuild: false)
    }

    func setClipFilter(_ filterID: String) {
        guard var clip = selectedClip else { return }
        performEdit("Clip Filter") {
            if clip.filterIDs.contains(filterID) {
                clip.filterIDs.removeAll { $0 == filterID }
            } else {
                clip.filterIDs = [filterID]
            }
            if let index = project.clips.firstIndex(where: { $0.id == clip.id }) {
                project.clips[index] = clip
            }
        }
    }

    func setGlobalFilter(_ filterID: String) {
        performEdit("Global Filter") {
            project.globalFilterIDs = filterID.isEmpty ? [] : [filterID]
        }
    }

    func setClipColorAdjustments(_ adjustments: ColorAdjustments, recordHistory: Bool = false) {
        guard let clipID = selectedClipID,
              let index = project.clips.firstIndex(where: { $0.id == clipID }) else { return }
        if !gestureEditRecorded {
            beginGestureEdit("Adjust Color")
        }
        project.clips[index].colorAdjustments = adjustments
        scheduleRebuild()
    }

    func setGlobalColorAdjustments(_ adjustments: ColorAdjustments, recordHistory: Bool = false) {
        if !gestureEditRecorded {
            beginGestureEdit("Adjust Color")
        }
        project.globalColorAdjustments = adjustments
        scheduleRebuild()
    }

    func commitColorAdjustmentChange() {
        endGestureEdit()
    }

    func resetClipColorAdjustments() {
        performEdit("Reset Color") {
            guard let clipID = selectedClipID,
                  let index = project.clips.firstIndex(where: { $0.id == clipID }) else { return }
            project.clips[index].colorAdjustments = .identity
        }
    }

    func resetGlobalColorAdjustments() {
        performEdit("Reset Color") {
            project.globalColorAdjustments = .identity
        }
    }

    func rotateClip90() {
        performEdit("Rotate Clip") {
            guard let clipID = selectedClipID,
                  let index = project.clips.firstIndex(where: { $0.id == clipID }) else { return }
            project.clips[index].framing.rotationQuarterTurns += 1
        }
    }

    func setClipZoom(_ zoom: CGFloat) {
        guard let clipID = selectedClipID,
              let index = project.clips.firstIndex(where: { $0.id == clipID }) else { return }
        if !gestureEditRecorded {
            beginGestureEdit("Transform Clip")
        }
        project.clips[index].framing.zoom = max(0.5, min(zoom, 3.0))
        scheduleRebuild()
    }

    func setClipOffset(_ offset: CGPoint) {
        guard let clipID = selectedClipID,
              let index = project.clips.firstIndex(where: { $0.id == clipID }) else { return }
        if !gestureEditRecorded {
            beginGestureEdit("Transform Clip")
        }
        project.clips[index].framing.offset = CGPoint(
            x: max(-1, min(1, offset.x)),
            y: max(-1, min(1, offset.y))
        )
        scheduleRebuild()
    }

    func setClipFit(_ fitMode: ClipFitMode) {
        performEdit("Fit Mode") {
            guard let clipID = selectedClipID,
                  let index = project.clips.firstIndex(where: { $0.id == clipID }) else { return }
            project.clips[index].framing.fitMode = fitMode
        }
    }

    func resetClipTransform() {
        performEdit("Reset Transform") {
            guard let clipID = selectedClipID,
                  let index = project.clips.firstIndex(where: { $0.id == clipID }) else { return }
            project.clips[index].framing = .identity
            project.clips[index].transform = .identity
        }
    }

    func commitClipTransformChange() {
        endGestureEdit()
    }

    func beginTikTokTextEntry() {
        guard canMutateComposer() else { return }
        selectedTool = .text
        prepareForTextToolPresentation()
        addTextOverlay(openComposer: true)
    }

    /// Visible text overlays at the current playhead (composer canvas source of truth).
    var composerLayers: [TextOverlay] {
        let time = currentTime
        return project.textOverlays.filter { overlay in
            time >= overlay.timeRange.start.seconds && time <= overlay.timeRange.endSeconds
        }
    }

    func setComposerMode(_ mode: TextComposerMode) {
        composerMode = mode
        if mode != .editing {
            composerEditingID = nil
        }
    }

    @discardableResult
    func canMutateComposer() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastComposerMutationAt >= composerMutationDebounce else { return false }
        lastComposerMutationAt = now
        return true
    }

    func addComposerLayer(at point: CGPoint? = nil) {
        guard canMutateComposer() else { return }
        guard isTextInputActive else {
            addTextOverlay(at: point, openComposer: true)
            return
        }
        let center = point ?? CGPoint(x: 0.5, y: 0.5)
        let end = min(currentTime + 3, max(totalDuration, currentTime + 3))
        let overlay = TextOverlay(
            text: "",
            timeRange: CMTimeRange(
                start: CMTime(seconds: currentTime, preferredTimescale: 600),
                end: CMTime(seconds: end, preferredTimescale: 600)
            ),
            style: SubtitleStyle(fontSize: 34, colorHex: textComposerColorHex, hasBackground: false),
            normalizedCenter: center
        )
        performEdit("Add Text", rebuild: false) {
            project.textOverlays.append(overlay)
            selectedTextID = overlay.id
            selectedTool = .text
        }
        composerSelectedID = overlay.id
        composerEditingID = overlay.id
        composerMode = .editing
        textComposerDraft = ""
        textComposerCenter = center
    }

    func switchComposerEditing(to id: UUID) {
        guard project.textOverlays.contains(where: { $0.id == id }) else { return }
        selectedTextID = id
        composerSelectedID = id
        composerEditingID = id
        composerMode = .editing
        let overlay = project.textOverlays.first(where: { $0.id == id })
        textComposerDraft = overlay?.text ?? ""
        textComposerColorHex = overlay?.style.colorHex ?? "#FFFFFF"
        textComposerCenter = overlay?.normalizedCenter ?? CGPoint(x: 0.5, y: 0.5)
    }

    func duplicateComposerLayer(_ id: UUID) {
        guard canMutateComposer() else { return }
        guard let source = project.textOverlays.first(where: { $0.id == id }) else { return }
        var copy = source
        let newID = UUID()
        copy = TextOverlay(
            id: newID,
            text: source.text,
            timeRange: source.timeRange,
            style: source.style,
            animation: source.animation,
            normalizedCenter: CGPoint(
                x: min(0.92, source.normalizedCenter.x + 0.03),
                y: min(0.92, source.normalizedCenter.y + 0.03)
            ),
            scale: source.scale,
            rotation: source.rotation,
            opacity: source.opacity
        )
        performEdit("Duplicate Text", rebuild: false) {
            project.textOverlays.append(copy)
            selectedTextID = newID
        }
        composerSelectedID = newID
        composerEditingID = nil
        composerMode = .manipulating
        OverlaySnapHaptics.snapOccurred()
    }

    func deleteComposerLayer(_ id: UUID) {
        guard canMutateComposer() else { return }
        performEdit("Delete Text", rebuild: false) {
            project.textOverlays.removeAll { $0.id == id }
            if selectedTextID == id { selectedTextID = nil }
        }
        if composerSelectedID == id { composerSelectedID = nil }
        if composerEditingID == id {
            composerEditingID = nil
            composerMode = .manipulating
        }
    }

    func applyComposerStyle(_ mutate: (inout TextOverlay) -> Void, for id: UUID? = nil) {
        let targetID = id ?? composerSelectedID ?? selectedTextID
        guard let targetID,
              let index = project.textOverlays.firstIndex(where: { $0.id == targetID })
        else { return }
        if !gestureEditRecorded {
            beginGestureEdit("Style Text")
        }
        var overlay = project.textOverlays[index]
        mutate(&overlay)
        project.textOverlays[index] = overlay
        textComposerColorHex = overlay.style.colorHex
        styleApplyTask?.cancel()
        styleApplyGeneration &+= 1
        let generation = styleApplyGeneration
        styleApplyTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled, generation == styleApplyGeneration else { return }
            // Keep draft in sync; final history commit on gesture end / Done.
        }
    }

    func commitComposerStyleChange() {
        endGestureEdit(rebuild: false)
    }

    func cancelTextComposerIfEmpty() {
        guard let selectedTextID,
              let overlay = project.textOverlays.first(where: { $0.id == selectedTextID }) else { return }
        let text = (displayText(for: selectedTextID) ?? overlay.text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text == "Text" {
            deleteSelectedTextOverlay()
        }
    }

    func addTextOverlay(at point: CGPoint? = nil, openComposer: Bool = true) {
        guard !isTextInputActive, pendingTextPromptID == nil else { return }
        let center = point ?? CGPoint(x: 0.5, y: 0.5)
        let end = min(currentTime + 3, max(totalDuration, currentTime + 3))
        let overlay = TextOverlay(
            text: "",
            timeRange: CMTimeRange(
                start: CMTime(seconds: currentTime, preferredTimescale: 600),
                end: CMTime(seconds: end, preferredTimescale: 600)
            ),
            style: SubtitleStyle(fontSize: 34, colorHex: "#FFFFFF", hasBackground: false),
            normalizedCenter: center
        )
        performEdit("Add Text", rebuild: false) {
            project.textOverlays.append(overlay)
            selectedTextID = overlay.id
            selectedTool = .text
        }
        if openComposer {
            requestTextPrompt(for: overlay.id)
        }
    }

    func selectTextOverlay(_ id: UUID) {
        selectedTextID = id
        selectedStickerID = nil
        selectedTool = .text
        if isTextInputActive {
            composerSelectedID = id
            composerMode = .manipulating
        }
    }

    func requestTextPrompt(for id: UUID) {
        selectedTextID = id
        selectedStickerID = nil
        selectedTool = .text
        composerSelectedID = id
        composerEditingID = id
        composerMode = .editing
        let overlay = project.textOverlays.first(where: { $0.id == id })
        let initial = displayText(for: id) ?? overlay?.text ?? ""
        textComposerDraft = (initial == "Text") ? "" : initial
        textComposerColorHex = overlay?.style.colorHex ?? "#FFFFFF"
        textComposerCenter = overlay?.normalizedCenter ?? CGPoint(x: 0.5, y: 0.5)
        if composerPauseVideoOnOpen {
            pausePlayback()
        }
        FilmstripExtractionService.shared.setSuspended(true)
        applyInstantHoldFrame()
        isPreviewDetached = true
        isolatePlaybackForTextInput()
        let captureTime = currentTime
        previewStillTask?.cancel()
        previewStillTask = Task { [weak self] in
            guard let self else { return nil }
            return await EditorStillCapture.image(from: self.project, at: captureTime)
        }
        Task { @MainActor [weak self] in
            guard let self, let image = await self.previewStillTask?.value else { return }
            self.lastPreviewStill = image
            self.textComposerSnapshot = image
            self.previewHoldFrame = image
        }
        // Do not flip `isTextInputActive` here — a sheet may still be dismissing.
        pendingTextPromptID = id
    }

    func prepareForTextToolPresentation() {
        if composerPauseVideoOnOpen {
            pausePlayback()
        }
        FilmstripExtractionService.shared.setSuspended(true)
    }

    func restorePreviewIfNeeded() {
        guard isPreviewDetached, !isTextInputActive, pendingTextPromptID == nil else { return }
        guard !EditorKeyboardPresence.isVisible else { return }
        reattachPreviewKeepingItem()
    }

    func beginPendingTextInputIfNeeded() {
        guard pendingTextPromptID != nil, !isTextInputActive else { return }
        let id = pendingTextPromptID
        pendingTextPromptID = nil
        if composerPauseVideoOnOpen {
            pausePlayback()
        }
        FilmstripExtractionService.shared.setSuspended(true)
        applyInstantHoldFrame()
        isPreviewDetached = true
        isolatePlaybackForTextInput()
        composerEditingID = id
        composerSelectedID = id
        composerMode = .editing
        isTextInputActive = true
    }

    func commitTextComposer(text: String, colorHex: String, center: CGPoint? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            cancelTextComposerIfEmpty()
            return
        }
        let id = selectedTextID ?? project.textOverlays.last?.id
        if let id {
            selectedTextID = id
            applyOverlayText(id, text, colorHex: colorHex, center: center)
        }
    }

    /// Commits all composer-visible layers (multi-layer session) then closes.
    func commitComposerSession(layers: [TextOverlay]) {
        for layer in layers {
            guard let index = project.textOverlays.firstIndex(where: { $0.id == layer.id }) else { continue }
            let trimmed = layer.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                project.textOverlays.removeAll { $0.id == layer.id }
                continue
            }
            var next = layer
            next.text = trimmed
            project.textOverlays[index] = next
        }
        // Drop leftover empty placeholders created during the session.
        let emptyIDs = project.textOverlays
            .filter { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(\.id)
        if !emptyIDs.isEmpty {
            performEdit("Clean Empty Text", rebuild: false) {
                project.textOverlays.removeAll { emptyIDs.contains($0.id) }
            }
        }
    }

    func finishTextInput() {
        textComposerOpenTask?.cancel()
        textComposerOpenTask = nil
        styleApplyTask?.cancel()
        styleApplyTask = nil
        if let still = textComposerSnapshot ?? lastPreviewStill {
            previewHoldFrame = still
            lastPreviewStill = still
        }
        isPreviewDetached = true
        isTextInputActive = false
        pendingTextPromptID = nil
        textComposerDraft = ""
        composerMode = .editing
        composerEditingID = nil
        composerSelectedID = nil
        errorMessage = nil
        selectedTool = .text
        FilmstripExtractionService.shared.setSuspended(false)
        OverlayRenderer.clearFontCache()
        EditorKeyboardDismiss.scheduleAfterComposerClosed()
        // Do not reattach AVPlayer here. Keyboard IME is often still alive
        // (`RTIInputSystemClient` / Fig XPC) and that pairing kills the process.
    }

    private func applyInstantHoldFrame() {
        if let current = previewHoldFrame {
            lastPreviewStill = current
            textComposerSnapshot = current
            return
        }
        if let last = lastPreviewStill {
            previewHoldFrame = last
            textComposerSnapshot = last
        }
    }

    private func isolatePlaybackForTextInput() {
        if let timeObserver {
            playbackEngine.player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
            teardownTimeObserver = nil
            teardownPlayer = nil
        }
        playbackEngine.abandonPlayer()
    }

    private func reattachPreviewKeepingItem() {
        isPreviewDetached = false
        FilmstripExtractionService.shared.setSuspended(false)
        setupTimeObserver()
        scheduleRebuild(seekTo: CMTime(seconds: currentTime, preferredTimescale: 600))
    }

    func applyOverlayText(_ id: UUID, _ text: String, colorHex: String? = nil, center: CGPoint? = nil) {
        guard let index = project.textOverlays.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? "Text" : trimmed
        let current = project.textOverlays[index]
        let textChanged = current.text != value
        let colorChanged = colorHex.map {
            current.style.colorHex.compare($0, options: .caseInsensitive) != .orderedSame
        } ?? false
        let centerChanged = center.map { $0 != current.normalizedCenter } ?? false
        guard textChanged || colorChanged || centerChanged else { return }
        textOverlayDraft.removeValue(forKey: id)
        performEdit("Edit Text", rebuild: false) {
            project.textOverlays[index].text = value
            if let colorHex {
                project.textOverlays[index].style.colorHex = colorHex
            }
            if let center {
                project.textOverlays[index].normalizedCenter = center
            }
        }
    }

    func endInlineTextEdit() {
        flushTextOverlayDraft()
        inlineEditingTextID = nil
        // Do not clear `pendingTextPromptID` — TextToolPanel.onDisappear calls
        // this while "Edit on Video" / Add Text is waiting to open the composer.
        if gestureEditRecorded {
            commitOverlayGestureChange()
        }
    }

    func addSticker(_ emoji: String) {
        let end = min(currentTime + 3, totalDuration)
        performEdit("Add Sticker", rebuild: false) {
            let overlay = StickerOverlay(
                emoji: emoji,
                timeRange: CMTimeRange(
                    start: CMTime(seconds: currentTime, preferredTimescale: 600),
                    end: CMTime(seconds: end, preferredTimescale: 600)
                )
            )
            project.stickerOverlays.append(overlay)
            selectedStickerID = overlay.id
            selectedTool = .text
            pendingToolPresentation = .text
        }
    }

    func addImageSticker(from url: URL) {
        let end = min(currentTime + 3, totalDuration)
        performEdit("Add Sticker", rebuild: false) {
            let overlay = StickerOverlay(
                emoji: nil,
                imageURL: url,
                timeRange: CMTimeRange(
                    start: CMTime(seconds: currentTime, preferredTimescale: 600),
                    end: CMTime(seconds: end, preferredTimescale: 600)
                )
            )
            project.stickerOverlays.append(overlay)
            selectedStickerID = overlay.id
            selectedTool = .text
            pendingToolPresentation = .text
        }
    }

    func addBundledSticker(_ kind: BundledStickerLibrary.StickerKind) {
        guard let url = BundledStickerLibrary.renderURL(for: kind) else { return }
        addImageSticker(from: url)
    }

    /// Prefer draft text while typing so the UITextField Binding stays in sync
    /// without forcing a project mutation on every keystroke.
    func displayText(for overlayID: UUID) -> String? {
        if let draft = textOverlayDraft[overlayID] { return draft }
        return project.textOverlays.first(where: { $0.id == overlayID })?.text
    }

    func updateTextOverlay(_ overlay: TextOverlay, recordHistory: Bool = false) {
        if recordHistory, !gestureEditRecorded {
            beginGestureEdit("Edit Text")
        }
        guard let index = project.textOverlays.firstIndex(where: { $0.id == overlay.id }) else { return }

        // Text-only live typing: debounce project mutation so the timeline
        // doesn't fully rebuild on every keystroke.
        let existing = project.textOverlays[index]
        let textOnlyChange = existing.text != overlay.text
            && existing.style == overlay.style
            && existing.normalizedCenter == overlay.normalizedCenter
            && existing.scale == overlay.scale
            && existing.rotation == overlay.rotation
            && existing.opacity == overlay.opacity
            && existing.timeRange == overlay.timeRange
            && existing.animation == overlay.animation

        if !recordHistory, textOnlyChange {
            if !gestureEditRecorded {
                beginGestureEdit("Edit Text")
            }
            textOverlayDraft[overlay.id] = overlay.text
            textCommitTask?.cancel()
            textCommitGeneration &+= 1
            let overlayID = overlay.id
            let generation = textCommitGeneration
            textCommitTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                guard generation == textCommitGeneration else { return }
                flushTextOverlayDraft(for: overlayID)
            }
            return
        }

        var next = overlay
        if let draft = textOverlayDraft[overlay.id] {
            next.text = draft
        }
        project.textOverlays[index] = next
    }

    func updateOverlayText(_ id: UUID, _ text: String) {
        guard var overlay = project.textOverlays.first(where: { $0.id == id }) else { return }
        overlay.text = text
        updateTextOverlay(overlay)
    }

    private func flushTextOverlayDraft(for id: UUID? = nil) {
        textCommitTask?.cancel()
        textCommitTask = nil
        let ids = id.map { [$0] } ?? Array(textOverlayDraft.keys)
        for overlayID in ids {
            guard let draft = textOverlayDraft.removeValue(forKey: overlayID),
                  let index = project.textOverlays.firstIndex(where: { $0.id == overlayID })
            else { continue }
            guard project.textOverlays[index].text != draft else { continue }
            project.textOverlays[index].text = draft
        }
    }

    func updateStickerOverlay(_ overlay: StickerOverlay, recordHistory: Bool = false) {
        if recordHistory, !gestureEditRecorded {
            beginGestureEdit("Edit Sticker")
        }
        guard let index = project.stickerOverlays.firstIndex(where: { $0.id == overlay.id }) else { return }
        project.stickerOverlays[index] = overlay
    }

    func commitOverlayGestureChange() {
        endGestureEdit(rebuild: false)
    }

    func deleteSelectedTextOverlay() {
        guard let selectedTextID else { return }
        performEdit("Delete Text", rebuild: false) {
            project.textOverlays.removeAll { $0.id == selectedTextID }
            self.selectedTextID = nil
        }
    }

    func deleteSelectedStickerOverlay() {
        guard let selectedStickerID else { return }
        performEdit("Delete Sticker", rebuild: false) {
            project.stickerOverlays.removeAll { $0.id == selectedStickerID }
            self.selectedStickerID = nil
            purgeUnreferencedTempMedia()
        }
    }

    func importClip(from item: PhotosPickerItem) async {
        guard await DevicePermissions.requestPhotoLibraryAccess() else {
            errorMessage = "Photo library access is required."
            return
        }
        guard let imported = try? await item.loadTransferable(type: ImportedMovieFile.self) else {
            errorMessage = "Could not import video."
            return
        }
        await appendImportedClip(url: imported.url)
    }

    func importPhoto(from item: PhotosPickerItem) async {
        guard await DevicePermissions.requestPhotoLibraryAccess() else {
            errorMessage = "Photo library access is required."
            return
        }
        guard let imported = try? await item.loadTransferable(type: ImportedImageFile.self) else {
            errorMessage = "Could not import photo."
            return
        }
        do {
            let videoURL = try await StillImageClipRenderer.renderVideo(from: imported.url)
            await appendImportedClip(url: videoURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importStickerImage(from item: PhotosPickerItem) async {
        guard await DevicePermissions.requestPhotoLibraryAccess() else {
            errorMessage = "Photo library access is required."
            return
        }
        guard let imported = try? await item.loadTransferable(type: ImportedImageFile.self) else { return }
        addImageSticker(from: imported.url)
    }

    private func appendImportedClip(url: URL) async {
        do {
            let asset = EditorAVAssetCache.shared.asset(for: url)
            let duration = try await asset.load(.duration)
            performEdit("Import Clip", rebuild: false) {
                project.clips.append(VideoClip.make(from: url, duration: duration))
                selectedClipID = project.clips.last?.id
            }
            scheduleRebuild()
            totalDuration = project.totalDurationSeconds
            await waveformStore.loadIfNeeded(for: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func appendClip(url: URL) async {
        await appendImportedClip(url: url)
    }

    func importMusic(from url: URL, title: String) async {
        do {
            let asset = EditorAVAssetCache.shared.asset(for: url)
            let duration = try await asset.load(.duration)
            performEdit("Add Music") {
                let track = AudioTrack(
                    sourceURL: url,
                    timeRange: CMTimeRange(start: .zero, duration: duration),
                    startTime: .zero,
                    kind: .music,
                    title: title
                )
                project.audioTracks.append(track)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addSoundEffect(_ effect: SoundEffect, at time: TimeInterval? = nil) async {
        do {
            let url = try SoundEffectAudioGenerator.url(for: effect)
            let asset = EditorAVAssetCache.shared.asset(for: url)
            let duration = try await asset.load(.duration)
            let start = CMTime(seconds: time ?? currentTime, preferredTimescale: 600)
            performEdit("Add Sound Effect") {
                let track = AudioTrack(
                    sourceURL: url,
                    timeRange: CMTimeRange(start: .zero, duration: duration),
                    startTime: start,
                    kind: .sfx,
                    title: effect.name
                )
                project.audioTracks.append(track)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func previewAudioTrack(_ track: AudioTrack) {
        guard let index = project.audioTracks.firstIndex(where: { $0.id == track.id }) else { return }
        project.audioTracks[index] = track
    }

    func commitAudioTrack(_ track: AudioTrack) {
        performEdit("Edit Audio Track") {
            previewAudioTrack(track)
        }
    }

    func updateAudioTrack(_ track: AudioTrack) {
        commitAudioTrack(track)
    }

    func setAudioTrackVolume(_ trackID: UUID, volume: Float) {
        guard let index = project.audioTracks.firstIndex(where: { $0.id == trackID }) else { return }
        if !gestureEditRecorded {
            beginGestureEdit("Adjust Volume")
        }
        project.audioTracks[index].volume = volume
        playbackEngine.updateAudioMix(from: project)
    }

    func commitAudioTrackVolumeChange() {
        endGestureEdit(rebuild: false)
    }

    func startVoiceover() async {
        playbackEngine.pause()
        isPlaying = false
        do {
            try await voiceoverRecorder.startRecording()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopVoiceover() {
        guard let url = voiceoverRecorder.stopRecording() else { return }
        let asset = EditorAVAssetCache.shared.asset(for: url)
        Task {
            let duration = (try? await asset.load(.duration)) ?? CMTime(seconds: 1, preferredTimescale: 600)
            let segment = VoiceoverSegment(
                fileURL: url,
                startTime: CMTime(seconds: currentTime, preferredTimescale: 600),
                duration: duration
            )
            performEdit("Record Voiceover") {
                if project.voiceoverTrack == nil {
                    project.voiceoverTrack = VoiceoverTrack(segments: [segment])
                } else {
                    project.voiceoverTrack?.segments.append(segment)
                }
            }
            voiceoverRecorder.releaseRecordedFileReference()
        }
    }

    func generateSubtitles() async {
        isGeneratingSubtitles = true
        subtitleGenerationProgress = "Transcribing..."
        defer {
            isGeneratingSubtitles = false
            subtitleGenerationProgress = nil
        }
        do {
            let track = try await subtitleGenerator.generate(for: project)
            performEdit("Generate Subtitles") {
                project.subtitleTrack = track
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateSubtitleText(_ id: UUID, _ text: String) {
        guard var segment = project.subtitleTrack?.segments.first(where: { $0.id == id }) else { return }
        guard segment.text != text else { return }
        segment.text = text
        previewSubtitleSegment(segment)
    }

    func previewSubtitleSegment(_ segment: SubtitleSegment) {
        guard var track = project.subtitleTrack,
              let index = track.segments.firstIndex(where: { $0.id == segment.id }) else { return }
        if !gestureEditRecorded {
            beginGestureEdit("Edit Subtitle")
        }
        track.segments[index] = segment
        project.subtitleTrack = track
    }

    func commitSubtitleSegment(_ segment: SubtitleSegment) {
        if gestureEditRecorded {
            if var track = project.subtitleTrack,
               let index = track.segments.firstIndex(where: { $0.id == segment.id }) {
                track.segments[index] = segment
                project.subtitleTrack = track
            }
            endGestureEdit(rebuild: false)
            return
        }
        performEdit("Edit Subtitle", rebuild: false) {
            guard var track = project.subtitleTrack,
                  let index = track.segments.firstIndex(where: { $0.id == segment.id }) else { return }
            track.segments[index] = segment
            project.subtitleTrack = track
        }
    }

    func updateSubtitleSegment(_ segment: SubtitleSegment) {
        previewSubtitleSegment(segment)
    }

    func applySubtitlePreset(_ preset: SubtitleStylePreset) {
        performEdit("Subtitle Style") {
            guard var track = project.subtitleTrack else {
                project.subtitleTrack = SubtitleTrack(style: .preset(preset))
                return
            }
            track.style = .preset(preset)
            project.subtitleTrack = track
        }
    }

    func export(quality: ExportQuality = .p1080) async throws -> URL {
        isExporting = true
        exportProgress = 0
        // Preview and export share EditorCompositorContext — detach preview first.
        pausePlayback()
        trimCommitTask?.cancel()
        trimCommitTask = nil
        if isClipTrimming {
            endClipTrimVisualFreeze()
        }
        greenScreenRebuildTask?.cancel()
        greenScreenRebuildTask = nil
        playbackEngine.suspendForExport()
        previewHoldFrame = nil

        // Free filmstrip / waveform memory before encode or reuse so Continue doesn't OOM.
        FilmstripExtractionService.shared.clearOnMemoryWarning()
        waveformStore.clear()
        Task { await WaveformGenerator.shared.clearCache() }

        let clipCount = project.clips.count
        PipelineLogger.editor.info(
            "EditorViewModel.export clips=\(clipCount) quality=\(quality.rawValue, privacy: .public)"
        )

        // Only delete prior *encoded* exports — never a reused camera/gallery source clip.
        if let lastExportURL,
           TemporaryCaptureStore.isManaged(lastExportURL),
           lastExportURL.lastPathComponent.hasPrefix("export-") {
            TemporaryCaptureStore.removeItem(at: lastExportURL)
        }

        do {
            let url = try await exportEngine.export(project: project, quality: quality) { [weak self] progress in
                Task { @MainActor in self?.exportProgress = progress }
            }
            lastExportURL = url
            PipelineLogger.editor.info("EditorViewModel.export success \(PipelineLogger.fileSummary(url), privacy: .public)")
            return url
        } catch {
            isExporting = false
            PipelineLogger.logError(PipelineLogger.editor, "EditorViewModel.export failed", error: error)
            // Restore preview after a failed export attempt.
            scheduleRebuild()
            throw error
        }
    }

    /// Full teardown before CameraView deletes source clips / swaps phase.
    func prepareHandoffAfterExport() {
        // Clears player, time observer, asset/filmstrip caches that may still hold files.
        cleanup()
        isExporting = false
        exportProgress = 1
    }

    @discardableResult
    func exportAndSaveToGallery(quality: ExportQuality = .p1080) async throws -> URL {
        isSavingToGallery = true
        gallerySaveMessage = nil
        defer {
            isSavingToGallery = false
            isExporting = false
        }

        let url = try await export(quality: quality)
        do {
            try await PhotoLibraryExporter.saveVideo(at: url)
            gallerySaveMessage = "Video saved to Photos"
        } catch {
            await playbackEngine.rebuildImmediately(from: project)
            setupTimeObserver()
            throw error
        }
        // Restore preview after suspendForExport() during export.
        await playbackEngine.rebuildImmediately(from: project)
        setupTimeObserver()
        return url
    }

    private func scheduleGreenScreenRebuild() {
        greenScreenRebuildTask?.cancel()
        greenScreenRebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.scheduleRebuild() }
        }
    }

    private func registerMemoryWarningObserver() {
        let observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard !ExportSessionGuard.isActive else {
                PipelineLogger.editor.warning("memory warning during export — skipping asset cache purge")
                return
            }
            Task { @MainActor in
                await WaveformGenerator.shared.clearCache()
                self?.waveformStore.clear()
                if let self {
                    let keep = self.project.referencedMediaURLs()
                    EditorAVAssetCache.shared.purgeUnreferenced(keeping: keep)
                }
                FilmstripExtractionService.shared.clearOnMemoryWarning()
                OverlayRenderer.clearFontCache()
                self?.previewHoldFrame = nil
                self?.lastPreviewStill = nil
                self?.textOverlayDraft.removeAll()
            }
        }
        memoryWarningObserver = observer
        teardownMemoryObserver = observer
    }

    private func setupTimeObserver() {
        if let timeObserver {
            playbackEngine.player.removeTimeObserver(timeObserver)
        }
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        let player = playbackEngine.player
        teardownPlayer = player
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                guard !self.isTextInputActive else { return }
                self.currentTime = time.seconds
                self.isPlaying = self.playbackEngine.isPlaying
                if self.isPlaying, time.seconds >= self.totalDuration - 0.05 {
                    self.playbackEngine.pause()
                    self.isPlaying = false
                }
            }
        }
        teardownTimeObserver = timeObserver
    }
}
