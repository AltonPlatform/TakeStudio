import PhotosUI
import SwiftUI
import UIKit

struct CameraView: View {
    @Bindable var viewModel: CameraViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedBackgroundItem: PhotosPickerItem?
    @State private var backgroundPickerIsVideo = false
    @State private var showGalleryPicker = false
    @State private var galleryPickerItems: [PhotosPickerItem] = []

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch viewModel.phase {
            case .capturing, .countdown:
                cameraScreen
            case .editing(let clips):
                EditorView(
                    clipURLs: clips,
                    onCancel: viewModel.cancelEditing,
                    onComplete: { exportURL in
                        viewModel.completeEditing(with: exportURL, sourceClipURLs: clips)
                    },
                    onReshoot: { viewModel.startEditorReshoot(existingClips: clips) }
                )
            }
        }
        .task {
            await viewModel.prepareIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                guard case .capturing = viewModel.phase else { return }
                Task { await viewModel.prepareIfNeeded() }
            case .background:
                Task { await viewModel.stopSessionUnlessPresentingGallery() }
            default:
                break
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
        .ignoresSafeArea(.keyboard, edges: .all)
        .photosPicker(
            isPresented: $showGalleryPicker,
            selection: $galleryPickerItems,
            maxSelectionCount: 10,
            matching: .videos,
            preferredItemEncoding: .current
        )
        .onChange(of: showGalleryPicker) { _, isShowing in
            if isShowing {
                viewModel.beginGalleryPresentation()
            } else if !viewModel.isImportingFromGallery && galleryPickerItems.isEmpty {
                viewModel.endGalleryPresentation()
            }
        }
        .onChange(of: galleryPickerItems) { _, items in
            guard !items.isEmpty else { return }
            let selected = items
            galleryPickerItems = []
            showGalleryPicker = false
            Task {
                await viewModel.importFromPhotosPickerItems(selected)
                viewModel.endGalleryPresentation()
            }
        }
        .onChange(of: viewModel.beautyIntensity) { _, _ in viewModel.syncProcessingSettingsPublic() }
        .onChange(of: viewModel.isGreenScreenEnabled) { _, _ in viewModel.syncProcessingSettingsPublic() }
        .onChange(of: viewModel.greenScreenMode) { _, _ in viewModel.syncProcessingSettingsPublic() }
        .onChange(of: viewModel.greenScreenSensitivity) { _, _ in viewModel.syncProcessingSettingsPublic() }
        .onChange(of: viewModel.greenScreenFeather) { _, _ in viewModel.syncProcessingSettingsPublic() }
        .onChange(of: viewModel.greenScreenBackgroundSource) { _, _ in viewModel.syncProcessingSettingsPublic() }
        .onChange(of: selectedBackgroundItem) { _, item in
            guard let item else { return }
            Task {
                await viewModel.importGreenScreenBackground(from: item, isVideo: backgroundPickerIsVideo)
                selectedBackgroundItem = nil
            }
        }
    }

    private var cameraScreen: some View {
        ZStack {
            MetalPreviewView(
                renderer: viewModel.previewRenderer,
                isActive: !viewModel.isImportingFromGallery
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()

            FocusIndicatorView(state: viewModel.focusIndicator)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            CameraPreviewInteractionOverlay(
                onFocus: viewModel.focus(at:lock:),
                onExposure: viewModel.setExposureBias,
                onZoom: viewModel.setZoom,
                onFlipCamera: { Task { await viewModel.flipCamera() } },
                focusIndicator: $viewModel.focusIndicator,
                zoomFactor: $viewModel.zoomFactor
            )
            .ignoresSafeArea()
            .allowsHitTesting(!viewModel.isGalleryPickerActive && !viewModel.isImportingFromGallery)

            if case .countdown(let seconds) = viewModel.phase {
                Text("\(seconds)")
                    .font(.system(size: 96, weight: .thin, design: .rounded))
                    .foregroundStyle(.white)
                    .allowsHitTesting(false)
            }

            if let errorMessage = viewModel.errorMessage {
                cameraErrorOverlay(message: errorMessage)
            }

            if viewModel.isInterrupted && !viewModel.isGalleryPickerActive {
                interruptionOverlay
            }

            if viewModel.isImportingFromGallery {
                galleryImportOverlay
            }

            VStack(spacing: 0) {
                topBar
                    .background(CameraTopBarBackground())

                Spacer()

                if viewModel.showAdvancedControls {
                    advancedControlsPanel
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if !viewModel.zoomStops.isEmpty {
                    CameraZoomRailView(
                        stops: viewModel.zoomStops,
                        selectedFactor: viewModel.zoomFactor,
                        onSelect: viewModel.selectZoom
                    )
                    .padding(.bottom, 8)
                }

                bottomControls
                    .background(CameraBottomBarBackground())
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: viewModel.showAdvancedControls)
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            // Keep left slot so flash/timer stay right-aligned (same geometry as AltonApp close button).
            Button {
                withAnimation { viewModel.showAdvancedControls.toggle() }
            } label: {
                Image(systemName: viewModel.showAdvancedControls ? "chevron.down" : "slider.horizontal.3")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(viewModel.showAdvancedControls ? CameraChrome.accent : .white)
                    .frame(width: CameraChrome.controlSize, height: CameraChrome.controlSize)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .opacity(viewModel.isRecording ? 0 : 1)
            .disabled(viewModel.isRecording)

            Spacer()

            if viewModel.isRecording {
                CameraRecordingIndicator(duration: viewModel.recordingDuration, isPaused: false)
            } else if let audioWarning = viewModel.audioWarning {
                Text(audioWarning)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.orange.opacity(0.85), in: Capsule())
                    .frame(maxWidth: 220)
            }

            Spacer()

            HStack(spacing: 8) {
                FlashToggle(
                    flashMode: viewModel.flashController.mode,
                    isVisible: viewModel.showsFlashControl,
                    action: viewModel.cycleFlashMode
                )
                TimerPickerLabel(delay: viewModel.timerDelay, action: viewModel.cycleTimerDelay)
            }
            .frame(minWidth: CameraChrome.controlSize * 2 + 8, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var advancedControlsPanel: some View {
        VStack(spacing: 12) {
            FilterCarousel(
                filters: viewModel.availableFilters,
                selectedFilterID: viewModel.activeFilterID,
                onSelect: viewModel.selectFilter
            )

            VStack(spacing: 10) {
                ExposureSlider(
                    bias: $viewModel.exposureBias,
                    range: viewModel.exposureController.minBias...viewModel.exposureController.maxBias,
                    onChange: viewModel.setExposureBias
                )

                HStack {
                    Label("Beauty", systemImage: "face.smiling")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                    Slider(value: $viewModel.beautyIntensity, in: 0...1)
                        .tint(CameraChrome.accent)
                }

                Toggle(isOn: $viewModel.isGreenScreenEnabled) {
                    Label("Green Screen", systemImage: "person.and.background.dotted")
                        .font(.caption.weight(.medium))
                }
                .tint(CameraChrome.accent)

                if viewModel.isGreenScreenEnabled {
                    greenScreenBackgroundControls
                }

                Button {
                    viewModel.cycleSpeed()
                } label: {
                    Label("Speed \(viewModel.speedController.speed.label)", systemImage: "gauge.with.dots.needle.67percent")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var greenScreenBackgroundControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Mode", selection: $viewModel.greenScreenMode) {
                Text("Auto Person").tag(GreenScreenMode.personSegmentation)
                Text("Chroma Key").tag(GreenScreenMode.chromaKey)
            }
            .pickerStyle(.segmented)

            HStack(spacing: 8) {
                Text("Background")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                ColorPicker(
                    "",
                    selection: Binding(
                        get: { greenScreenBackgroundColor },
                        set: { viewModel.setGreenScreenBackgroundColor($0) }
                    )
                )
                .labelsHidden()

                PhotosPicker(selection: $selectedBackgroundItem, matching: .images) {
                    Label("Image", systemImage: "photo")
                        .font(.caption)
                }
                .simultaneousGesture(TapGesture().onEnded { backgroundPickerIsVideo = false })

                PhotosPicker(selection: $selectedBackgroundItem, matching: .videos) {
                    Label("Video", systemImage: "film")
                        .font(.caption)
                }
                .simultaneousGesture(TapGesture().onEnded { backgroundPickerIsVideo = true })
            }

            if viewModel.greenScreenMode == .chromaKey {
                LabeledContent("Sensitivity") {
                    Slider(value: $viewModel.greenScreenSensitivity, in: 0...1)
                        .tint(CameraChrome.accent)
                }
                .font(.caption)
            }

            LabeledContent("Feather") {
                Slider(value: $viewModel.greenScreenFeather, in: 0...1)
                    .tint(CameraChrome.accent)
            }
            .font(.caption)
        }
    }

    private func openGalleryPicker() {
        viewModel.beginGalleryPresentation()
        showGalleryPicker = true
    }

    private var greenScreenBackgroundColor: Color {
        guard case .color(let hex) = viewModel.greenScreenBackgroundSource else {
            return Color(red: 0.1, green: 0.15, blue: 0.35)
        }
        return Color(hex: hex) ?? Color(red: 0.1, green: 0.15, blue: 0.35)
    }

    private var bottomControls: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center) {
                GalleryButton(action: openGalleryPicker)
                    .frame(width: 72, alignment: .leading)
                    .disabled(!viewModel.isCameraReady || viewModel.isImportingFromGallery)

                Spacer()

                CaptureButton(
                    captureMode: viewModel.captureMode,
                    isRecording: viewModel.isRecording,
                    progress: viewModel.recordingProgress,
                    isCameraReady: viewModel.isCameraReady && !viewModel.isImportingFromGallery,
                    isPreparing: viewModel.isPreparing
                ) {
                    viewModel.shutterTapped()
                }
                .disabled(viewModel.isImportingFromGallery)

                Spacer()

                Button {
                    Task { await viewModel.flipCamera() }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .disabled(!viewModel.isCameraReady)
                .frame(width: 72, alignment: .trailing)
            }
            .padding(.horizontal, 24)

            CaptureModeSelector(
                selectedMode: $viewModel.captureMode,
                onModeChanged: viewModel.selectCaptureMode
            )
            .disabled(viewModel.isRecording)
            .opacity(viewModel.isRecording ? 0.5 : 1)
        }
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    private var galleryImportOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.2)
                Text("Importing...")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .allowsHitTesting(true)
    }

    private var interruptionOverlay: some View {
        Button {
            viewModel.resumeCamera()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "pause.circle")
                    .font(.title)
                    .foregroundStyle(.white)
                Text("Camera paused")
                    .font(.subheadline)
                    .foregroundStyle(.white)
                Text("Tap to resume")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(20)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func cameraErrorOverlay(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.fill")
                .font(.system(size: 36))
                .foregroundStyle(.white)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
            Button("Open Settings") {
                DevicePermissions.openSettings()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.75))
    }
}

private extension Color {
    init?(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
