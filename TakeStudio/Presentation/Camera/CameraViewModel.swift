import AVFoundation
import Observation
import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
@Observable
final class CameraViewModel: FrameProcessorDelegate, CameraSessionDelegate {
    enum Phase: Equatable {
        case capturing
        case countdown(Int)
        case editing(clips: [URL])
    }

    var captureMode: CaptureMode = .video15
    var flashController = FlashController()
    var timerDelay: TimerDelay = .none
    var exposureController = ExposureController()
    var speedController = SpeedController()
    var activeFilterID: String = "original"
    var beautyIntensity: Double = 0
    var exposureBias: Float = 0
    var isGreenScreenEnabled = false
    var greenScreenMode: GreenScreenMode = .personSegmentation
    var greenScreenSensitivity: Double = 0.35
    var greenScreenFeather: Double = 0.5
    var greenScreenBackgroundSource: BackgroundSource = .color(hex: "#1A2640")
    var isRecording = false
    var recordingProgress: Double = 0
    var recordingDuration: TimeInterval = 0
    var phase: Phase = .capturing
    var focusIndicator: FocusIndicatorState?
    var zoomFactor: CGFloat = 1.0
    var errorMessage: String?
    var isInterrupted = false
    var isCameraReady = false
    var isPreparing = true
    var isImportingFromGallery = false
    var isGalleryPickerActive = false
    var isAudioEnabled = false
    var audioWarning: String?
    var showAdvancedControls = false

    let cameraSession: CameraSession
    private let timerController = TimerController()
    private var prepareGeneration = 0
    private var hasPreparedSession = false
    private var recordingTimer: Timer?
    private var recordingStartedAt: Date?
    private var isEditorReshoot = false
    private var editorReshootClips: [URL] = []

    let availableFilters: [any CameraFilter] = BuiltInCameraFilter.allFilters

    var cameraPosition: AVCaptureDevice.Position { cameraSession.cameraPosition }
    var zoomStops: [ZoomStop] { cameraSession.zoomStops }
    var previewRenderer: MetalPreviewRenderer { cameraSession.frameProcessor.previewRenderer }

    var showsFlashControl: Bool {
        cameraSession.hasTorch
    }

    init() {
        self.cameraSession = CameraSession()
        cameraSession.delegate = self
        cameraSession.frameProcessor.delegate = self
        configureTimerController()
        syncProcessingSettings()
    }

    func prepareIfNeeded() async {
        if hasPreparedSession {
            guard case .capturing = phase else { return }
            cameraSession.setAutomaticLifecycleEnabled(true)
            cameraSession.resumeIfNeeded()
            isCameraReady = true
            isPreparing = false
            isInterrupted = false
            return
        }
        await prepare()
    }

    func prepare() async {
        prepareGeneration += 1
        let generation = prepareGeneration
        isPreparing = true
        isCameraReady = false
        errorMessage = nil
        isInterrupted = false
        CaptureOrientationManager.refreshCachedOrientation()

        do {
            try await cameraSession.configure(enableMicrophone: true)
            guard generation == prepareGeneration else { return }
            cameraSession.startRunning()
            zoomFactor = cameraSession.zoomFactor
            exposureController.syncLimits(from: cameraSession.deviceManager)
            syncProcessingSettings()
            isAudioEnabled = cameraSession.isAudioCaptureEnabled
            audioWarning = isAudioEnabled
                ? nil
                : CaptureError.permissionDenied(.microphone).errorDescription
            isCameraReady = true
            hasPreparedSession = true
            cameraSession.warmUpRecording()
            Task.detached(priority: .utility) {
                _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            }
        } catch {
            guard generation == prepareGeneration else { return }
            errorMessage = error.localizedDescription
            isCameraReady = false
            hasPreparedSession = false
        }
        isPreparing = false
    }

    func stopSessionUnlessPresentingGallery() async {
        guard !isGalleryPickerActive else { return }
        await stopSession()
    }

    func stopSession() async {
        prepareGeneration += 1
        stopRecordingTimer()
        timerController.cancel()
        if isRecording {
            cameraSession.cancelRecording()
            isRecording = false
        }
        await cameraSession.shutdown()
        isInterrupted = false
        isCameraReady = false
        isPreparing = false
        hasPreparedSession = false
        errorMessage = nil
    }

    func beginGalleryPresentation() {
        isGalleryPickerActive = true
        isInterrupted = false
        cameraSession.setAutomaticLifecycleEnabled(false)
    }

    func endGalleryPresentation() {
        isGalleryPickerActive = false
        isInterrupted = false
        cameraSession.setAutomaticLifecycleEnabled(true)
        guard case .capturing = phase else { return }
        cameraSession.resumeIfNeeded()
    }

    func selectCaptureMode(_ mode: CaptureMode) {
        if isRecording {
            Task { await stopRecordingAndPreview() }
        }
        captureMode = mode
        syncProcessingSettings()
    }

    func cycleFlashMode() {
        flashController.cycle()
    }

    func cycleTimerDelay() {
        timerDelay = timerDelay.next()
    }

    func cycleSpeed() {
        speedController.cycle()
        Task {
            try? await cameraSession.setCaptureSpeed(speedController.speed)
        }
    }

    func selectFilter(_ filter: any CameraFilter) {
        activeFilterID = filter.id
        cameraSession.frameProcessor.filterEngine.activeFilter = filter.id == "original" ? nil : filter
    }

    func flipCamera() async {
        do {
            try await cameraSession.flipCamera(enableMicrophone: true)
            zoomFactor = cameraSession.zoomFactor
            syncProcessingSettings()
            CaptureOrientationManager.refreshCachedOrientation()
            cameraSession.warmUpRecording()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectZoom(_ factor: CGFloat) {
        zoomFactor = factor
        cameraSession.setZoomFactor(factor)
    }

    func setZoom(_ factor: CGFloat) {
        zoomFactor = factor
        cameraSession.setZoomFactor(factor)
    }

    func focus(at normalizedPoint: CGPoint, lock: Bool) {
        cameraSession.focus(at: normalizedPoint, lock: lock)
    }

    func setExposureBias(_ bias: Float) {
        let clamped = exposureController.clampedBias(bias)
        exposureBias = clamped
        exposureController.bias = clamped
        cameraSession.setExposureBias(clamped)
    }

    func shutterTapped() {
        toggleRecording()
    }

    func toggleRecording() {
        if isRecording {
            Task { await stopRecordingAndPreview() }
        } else if timerDelay == .none {
            startRecording()
        } else {
            timerController.start(delay: timerDelay)
        }
    }

    func cancelEditing() {
        if case .editing(let clips) = phase {
            clips.forEach { TemporaryCaptureStore.removeItem(at: $0) }
        }
        phase = .capturing
        recordingDuration = 0
        recordingProgress = 0
        isEditorReshoot = false
        editorReshootClips = []
        stopRecordingTimer()
        Task {
            try? CameraSessionConfigurator.configureAudioSession(cameraPosition: cameraPosition)
            await cameraSession.restoreCaptureAfterEditor()
            isCameraReady = true
        }
    }

    func completeEditing(with exportURL: URL, sourceClipURLs: [URL]) {
        phase = .capturing
        recordingDuration = 0
        recordingProgress = 0
        isEditorReshoot = false
        editorReshootClips = []
        Task { @MainActor in
            for _ in 0..<5 {
                await Task.yield()
            }
            try? await Task.sleep(for: .milliseconds(300))
            TemporaryCaptureStore.purgeUnreferenced(keeping: [])
            TemporaryCaptureStore.removeIfManaged(exportURL)
            for url in sourceClipURLs where url != exportURL {
                TemporaryCaptureStore.removeIfManaged(url)
            }
            try? CameraSessionConfigurator.configureAudioSession(cameraPosition: cameraPosition)
            await cameraSession.restoreCaptureAfterEditor()
            isCameraReady = true
        }
    }

    func startEditorReshoot(existingClips: [URL]) {
        editorReshootClips = existingClips
        isEditorReshoot = true
        phase = .capturing
        recordingDuration = 0
        recordingProgress = 0
        Task {
            try? CameraSessionConfigurator.configureAudioSession(cameraPosition: cameraPosition)
            await cameraSession.restoreCaptureAfterEditor()
            isCameraReady = true
        }
    }

    func importFromPhotosPickerItems(_ items: [PhotosPickerItem]) async {
        guard !isImportingFromGallery, !items.isEmpty else { return }
        isImportingFromGallery = true
        isInterrupted = false
        errorMessage = nil

        do {
            var picked: [GalleryPickerPresenter.PickedMedia] = []
            picked.reserveCapacity(min(items.count, 10))

            for item in items.prefix(10) {
                let isVideo = item.supportedContentTypes.contains { type in
                    type.conforms(to: .movie) || type.conforms(to: .video) || type.conforms(to: .mpeg4Movie)
                }
                if isVideo {
                    guard let imported = try await item.loadTransferable(type: ImportedMovieFile.self) else {
                        continue
                    }
                    picked.append(.init(url: imported.url, isVideo: true))
                }
            }

            guard !picked.isEmpty else {
                errorMessage = "Could not import selected media. Choose a video."
                isImportingFromGallery = false
                return
            }

            await applyImportedGalleryMedia(picked)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isImportingFromGallery = false
        }
    }

    func importFromGalleryFiles(_ items: [GalleryPickerPresenter.PickedMedia]) async {
        guard !isImportingFromGallery, !items.isEmpty else { return }
        isGalleryPickerActive = false
        isInterrupted = false
        isImportingFromGallery = true
        errorMessage = nil
        let videos = items.filter(\.isVideo)
        guard !videos.isEmpty else {
            errorMessage = "Could not import selected media. Choose a video."
            isImportingFromGallery = false
            return
        }
        await applyImportedGalleryMedia(videos)
    }

    private func applyImportedGalleryMedia(_ items: [GalleryPickerPresenter.PickedMedia]) async {
        defer { isImportingFromGallery = false }

        let clipURLs = items.filter(\.isVideo).map(\.url)
        guard !clipURLs.isEmpty else {
            errorMessage = "Could not import selected media. Choose a video."
            return
        }
        await cameraSession.releaseCaptureForEditor()
        isCameraReady = false
        phase = .editing(clips: clipURLs)
    }

    func importFromGalleryFile(url: URL, isVideo: Bool) async {
        guard isVideo else {
            errorMessage = "Only videos can be imported."
            return
        }
        await importFromGalleryFiles([.init(url: url, isVideo: true)])
    }

    func importFromGallery(_ item: PhotosPickerItem) async {
        guard !isImportingFromGallery else { return }
        isGalleryPickerActive = false
        isInterrupted = false

        guard await DevicePermissions.requestPhotoLibraryAccess() else {
            errorMessage = "Photo library access is required."
            return
        }

        let isVideo = item.supportedContentTypes.contains { type in
            type.conforms(to: .movie) || type.conforms(to: .video) || type.conforms(to: .mpeg4Movie)
        }
        guard isVideo else {
            errorMessage = "Only videos can be imported."
            return
        }

        isImportingFromGallery = true
        errorMessage = nil
        defer { isImportingFromGallery = false }

        do {
            guard let imported = try await item.loadTransferable(type: ImportedMovieFile.self) else {
                errorMessage = "Could not import video."
                return
            }
            await cameraSession.releaseCaptureForEditor()
            isCameraReady = false
            phase = .editing(clips: [imported.url])
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func frameProcessor(_ processor: FrameProcessor, didUpdateDuration duration: TimeInterval, progress: Double) {
        if speedController.speed != .normal {
            recordingDuration = duration
        }
        recordingProgress = progress
    }

    func frameProcessorDidReachDurationLimit(_ processor: FrameProcessor) {
        guard isRecording else { return }
        Task { await stopRecordingAndPreview() }
    }

    func cameraSession(_ session: CameraSession, didChangeInterruption interrupted: Bool) {
        guard !isGalleryPickerActive else {
            if !interrupted { isInterrupted = false }
            return
        }
        isInterrupted = interrupted
    }

    func syncProcessingSettingsPublic() {
        syncProcessingSettings()
    }

    func resumeCamera() {
        cameraSession.resumeIfNeeded()
        isInterrupted = false
    }

    private func configureTimerController() {
        timerController.onTick = { [weak self] remaining in
            self?.phase = .countdown(remaining)
        }
        timerController.onComplete = { [weak self] in
            guard let self else { return }
            self.phase = .capturing
            self.startRecording()
        }
    }

    func setGreenScreenBackgroundColor(_ color: Color) {
        greenScreenBackgroundSource = .color(hex: hexFromColor(color))
        syncProcessingSettings()
    }

    func importGreenScreenBackground(from item: PhotosPickerItem, isVideo: Bool) async {
        if isVideo {
            guard let imported = try? await item.loadTransferable(type: ImportedMovieFile.self) else { return }
            greenScreenBackgroundSource = .videoURL(imported.url)
        } else {
            guard let imported = try? await item.loadTransferable(type: ImportedImageFile.self) else { return }
            greenScreenBackgroundSource = .image(imported.url)
        }
        syncProcessingSettings()
    }

    private func syncProcessingSettings() {
        let processor = cameraSession.frameProcessor
        processor.beautyProcessor.intensity = beautyIntensity
        processor.faceAwareExposureEnabled = beautyIntensity > 0
        processor.durationLimit = captureMode.durationLimit
        processor.onFaceDetected = { [weak self] point in
            self?.cameraSession.focus(at: point, lock: false)
        }

        let greenScreen = processor.greenScreenProcessor
        if isGreenScreenEnabled {
            let effect = GreenScreenEffect(
                mode: greenScreenMode,
                sensitivity: greenScreenSensitivity,
                feather: greenScreenFeather,
                backgroundSource: greenScreenBackgroundSource
            )
            greenScreen.configure(from: effect)
        } else {
            greenScreen.isEnabled = false
            greenScreen.reset()
        }

        if let filter = availableFilters.first(where: { $0.id == activeFilterID }) {
            processor.filterEngine.activeFilter = filter.id == "original" ? nil : filter
        }
    }

    private func hexFromColor(_ color: Color) -> String {
        let uiColor = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    private func startRecording() {
        guard captureMode.isVideo else { return }

        Task {
            syncProcessingSettings()
            CaptureOrientationManager.refreshCachedOrientation()
            cameraSession.frameProcessor.resetRecordingState()
            isRecording = true
            recordingDuration = 0
            recordingProgress = 0
            startRecordingTimer()
            phase = .capturing

            do {
                try await cameraSession.startRecording(flashMode: flashController.mode.asCameraFlashMode)
            } catch {
                isRecording = false
                stopRecordingTimer()
                recordingDuration = 0
                recordingProgress = 0
                errorMessage = error.localizedDescription
            }
        }
    }

    private func stopRecordingAndPreview() async {
        guard isRecording else { return }
        isRecording = false
        stopRecordingTimer()
        defer { isInterrupted = false }
        do {
            let url = try await cameraSession.finishRecording(resumeCaptureAfterFinish: false)
            await cameraSession.releaseCaptureForEditor()
            isCameraReady = false
            if isEditorReshoot {
                var clips = editorReshootClips
                clips.append(url)
                editorReshootClips = []
                isEditorReshoot = false
                phase = .editing(clips: clips)
            } else {
                phase = .editing(clips: [url])
            }
        } catch {
            errorMessage = error.localizedDescription
            phase = .capturing
            cameraSession.resumeIfNeeded()
            isCameraReady = true
        }
    }

    private func startRecordingTimer() {
        stopRecordingTimer()
        recordingStartedAt = Date()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording, let start = self.recordingStartedAt else { return }
                self.recordingDuration = Date().timeIntervalSince(start)
                if let limit = self.captureMode.durationLimit, limit > 0 {
                    self.recordingProgress = min(self.recordingDuration / limit, 1)
                    if self.recordingDuration >= limit {
                        await self.stopRecordingAndPreview()
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        recordingTimer = timer
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartedAt = nil
    }
}

private extension FlashMode {
    var asCameraFlashMode: CameraFlashMode {
        switch self {
        case .off: return .off
        case .on: return .on
        case .auto: return .auto
        }
    }
}
