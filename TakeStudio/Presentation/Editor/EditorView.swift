import AVFoundation
import AVKit
import PhotosUI
import SwiftUI
import UIKit

struct EditorView: View {
    let clipURLs: [URL]
    let onCancel: () -> Void
    let onComplete: (URL) -> Void
    var onReshoot: (() -> Void)?

    @State private var viewModel: EditorViewModel?
    @State private var selectedVideoItem: PhotosPickerItem?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var activeSheet: EditorActiveSheet?
    @State private var isFullscreenPresented = false
    @State private var loadingProgress: Double = 0
    @State private var loadingMessage = "Preparing video…"
    @State private var loadError: String?
    @State private var gallerySaveAlertMessage: String?

    private let bottomToolbarHeight: CGFloat = 64

    private var presentedTool: EditorTool? {
        if case .tool(let tool) = activeSheet { return tool }
        return nil
    }

    private var isLoading: Bool {
        viewModel == nil || viewModel?.isBootstrapping == true || loadError != nil
    }

    private var displayedLoadingProgress: Double {
        if let viewModel, viewModel.isBootstrapping {
            return 0.35 + viewModel.bootstrapProgress * 0.65
        }
        return loadingProgress
    }

    private var displayedLoadingMessage: String {
        if let viewModel, viewModel.isBootstrapping {
            return viewModel.bootstrapMessage
        }
        return loadingMessage
    }

    var body: some View {
        rootStack
            .modifier(EditorSheetObserver(
                activeSheet: $activeSheet,
                viewModel: viewModel,
                onChange: { oldSheet, sheet in
                    handleActiveSheetChange(from: oldSheet, to: sheet)
                }
            ))
            .sheet(item: Binding(
                get: {
                    if viewModel?.isTextInputActive == true || viewModel?.pendingTextPromptID != nil {
                        return nil
                    }
                    return activeSheet
                },
                set: { activeSheet = $0 }
            )) { sheet in
                if let viewModel {
                    activeSheetContent(sheet, viewModel: viewModel)
                }
            }
            .task(id: clipURLs.map(\.path)) {
                await loadEditor()
            }
            .onDisappear {
                viewModel?.cleanup()
            }
            .alert("Photos", isPresented: Binding(
                get: { gallerySaveAlertMessage != nil },
                set: { if !$0 { gallerySaveAlertMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(gallerySaveAlertMessage ?? "")
            }
            .preferredColorScheme(.dark)
    }

    private func handleActiveSheetChange(from oldSheet: EditorActiveSheet?, to sheet: EditorActiveSheet?) {
        guard let viewModel else { return }
        switch sheet {
        case .tool(let tool):
            viewModel.selectedTool = tool
        case .none:
            if oldSheet == .history {
                viewModel.showHistorySheet = false
            }
            viewModel.pendingTransitionClipID = nil
            viewModel.pendingClipActionsClipID = nil
            if oldSheet == .music {
                activeSheet = .tool(.audio)
                return
            }
            // Re-present speed/edit tool after clip-actions dismiss settles.
            if viewModel.showSpeedPanel {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    guard viewModel.showSpeedPanel else { return }
                    activeSheet = .tool(.edit)
                    viewModel.showSpeedPanel = false
                }
                return
            }
            if viewModel.pendingTextPromptID != nil {
                Task { @MainActor in
                    // Let the sheet animation finish before the keyboard attaches.
                    try? await Task.sleep(for: .milliseconds(200))
                    guard viewModel.pendingTextPromptID != nil else { return }
                    viewModel.beginPendingTextInputIfNeeded()
                }
                return
            }
            if oldSheet == .tool(.text) {
                viewModel.restorePreviewIfNeeded()
            }
            // Keep Text selected after the sheet closes so tap-to-place still works
            // without reopening a sheet (and without fighting the keyboard).
            if viewModel.selectedTool != .transform,
               viewModel.selectedTool != .text,
               viewModel.inlineEditingTextID == nil {
                viewModel.selectedTool = .edit
            }
        default:
            break
        }
    }

    @ViewBuilder
    private var rootStack: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let viewModel, !viewModel.isBootstrapping {
                editorContent(viewModel: viewModel)
                    .disabled(
                        viewModel.isExporting
                        || viewModel.isSavingToGallery
                        || viewModel.isTextInputActive
                    )
                    .allowsHitTesting(!viewModel.isTextInputActive)
                    .ignoresSafeArea(.keyboard, edges: .all)

                if viewModel.isTextInputActive {
                    EditorTextComposerHost(
                        viewModel: viewModel,
                        onCommit: { result in
                            // Multi-layer commit already applied inside the composer VC.
                            // Keep single-layer path for empty/cancel cleanup.
                            if result == nil {
                                viewModel.cancelTextComposerIfEmpty()
                            }
                        },
                        onClose: {
                            activeSheet = nil
                            isFullscreenPresented = false
                            viewModel.finishTextInput()
                        }
                    )
                    .ignoresSafeArea()
                    .transition(.identity)
                    .zIndex(20)
                }

                if viewModel.isExporting || viewModel.isSavingToGallery {
                    exportOverlay(viewModel: viewModel)
                        .zIndex(100)
                }
            }

            if isFullscreenPresented, let viewModel, !viewModel.isBootstrapping, !viewModel.isTextInputActive {
                EditorFullscreenDismissibleView(
                    player: viewModel.player,
                    viewModel: viewModel,
                    isPresented: $isFullscreenPresented
                )
                .transition(.identity)
                .zIndex(10)
                .allowsHitTesting(!(viewModel.isExporting || viewModel.isSavingToGallery))
            }

            if isLoading, viewModel?.isTextInputActive != true {
                loadingOverlay
            }
        }
        .onChange(of: viewModel?.pendingTextPromptID) { _, id in
            guard id != nil, let viewModel else { return }
            isFullscreenPresented = false
            if activeSheet != nil {
                activeSheet = nil
            } else {
                viewModel.beginPendingTextInputIfNeeded()
            }
        }
    }

    @ViewBuilder
    private var loadingOverlay: some View {
        if let loadError {
            ZStack {
                EditorLoadingOverlay(progress: loadingProgress, message: loadError)
                VStack {
                    Spacer()
                    Button(action: onCancel) {
                        Label("Back", systemImage: "chevron.left")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(.white.opacity(0.18), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 48)
                }
            }
        } else {
            EditorLoadingOverlay(
                progress: displayedLoadingProgress,
                message: displayedLoadingMessage
            )
        }
    }

    @ViewBuilder
    private func activeSheetContent(_ sheet: EditorActiveSheet, viewModel: EditorViewModel) -> some View {
        switch sheet {
        case .tool(let tool):
            EditorToolSheet(tool: tool, viewModel: viewModel)
        case .history:
            EditorHistorySheet(viewModel: viewModel)
        case .music:
            MusicPickerView(
                onPick: { url, title in
                    Task { await viewModel.importMusic(from: url, title: title) }
                    activeSheet = .tool(.audio)
                },
                onCancel: {
                    activeSheet = .tool(.audio)
                }
            )
            .ignoresSafeArea()
        case .transition(let clipID):
            TransitionPickerSheet(
                clip: viewModel.project.clips.first(where: { $0.id == clipID }),
                onSelect: { transition, duration in
                    // Dismiss first so sheet teardown isn't competing with composition rebuild.
                    activeSheet = nil
                    Task { @MainActor in
                        viewModel.setClipTransition(transition, duration: duration, for: clipID)
                    }
                }
            )
            .presentationDetents([.medium, .large])
        case .clipActions(let clipID):
            if let clip = viewModel.project.clips.first(where: { $0.id == clipID }) {
                EditorClipActionsSheet(clip: clip, viewModel: viewModel) {
                    activeSheet = nil
                }
            }
        }
    }

    private func loadEditor() async {
        guard viewModel == nil else { return }

        loadError = nil
        loadingProgress = 0.08
        loadingMessage = "Reading video…"

        do {
            let project: EditorProject
            if clipURLs.count == 1, let url = clipURLs.first {
                project = try await EditorProject.fromInitialVideo(url: url)
            } else {
                loadingMessage = "Reading clips…"
                loadingProgress = 0.18
                project = try await EditorProject.fromClipURLs(clipURLs)
            }

            loadingProgress = 0.32
            loadingMessage = "Opening editor…"

            let model = EditorViewModel(project: project)
            viewModel = model

            while model.isBootstrapping {
                try? await Task.sleep(for: .milliseconds(30))
            }

            loadingProgress = 1
        } catch {
            loadError = error.localizedDescription
            loadingMessage = "Failed to load video"
        }
    }

    @ViewBuilder
    private func editorContent(viewModel: EditorViewModel) -> some View {
        EditorResizableZone(
            viewModel: viewModel,
            isFullscreenPresented: $isFullscreenPresented,
            allowOverlayPlacement: activeSheet == nil
        )
            .safeAreaInset(edge: .top, spacing: 0) {
                previewTopBar(viewModel: viewModel)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .opacity(viewModel.isTextInputActive ? 0 : 1)
                    .allowsHitTesting(!viewModel.isTextInputActive)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomToolbar(viewModel: viewModel)
                    .opacity(viewModel.isTextInputActive ? 0 : 1)
                    .allowsHitTesting(!viewModel.isTextInputActive)
            }
    }

    @ViewBuilder
    private func previewTopBar(viewModel: EditorViewModel) -> some View {
        HStack {
            Button(action: onCancel) {
                Label("Back", systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isExporting || viewModel.isSavingToGallery)

            Spacer()

            Button {
                viewModel.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .foregroundStyle(viewModel.canUndo ? .white : .gray)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canUndo || viewModel.isExporting || viewModel.isSavingToGallery)
            .accessibilityLabel("Undo")
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5)
                    .onEnded { _ in
                        if viewModel.canUndo {
                            activeSheet = nil
                            viewModel.showHistorySheet = true
                        }
                    }
            )

            Button {
                viewModel.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .foregroundStyle(viewModel.canRedo ? .white : .gray)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canRedo || viewModel.isExporting || viewModel.isSavingToGallery)
            .accessibilityLabel("Redo")

            Spacer(minLength: 8)

            Button {
                Task {
                    do {
                        let url = try await viewModel.exportAndSaveToGallery()
                        gallerySaveAlertMessage = viewModel.gallerySaveMessage
                        viewModel.prepareHandoffAfterExport()
                        await Task.yield()
                        onComplete(url)
                    } catch {
                        viewModel.errorMessage = error.localizedDescription
                    }
                }
            } label: {
                if viewModel.isSavingToGallery {
                    ProgressView()
                        .tint(.black)
                } else {
                    Text("Save")
                        .fontWeight(.semibold)
                        .foregroundStyle(.black)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .accessibilityLabel("Save to Photos")
            .disabled(viewModel.isExporting || viewModel.isSavingToGallery || viewModel.project.clips.isEmpty)
        }
    }

    @ViewBuilder
    private func bottomToolbar(viewModel: EditorViewModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                EditorToolbarButton(
                    icon: "scissors",
                    label: "Split",
                    isDisabled: !canSplitAtPlayhead(viewModel: viewModel),
                    action: {
                        Task { await viewModel.splitClip(at: viewModel.currentTime) }
                    }
                )

                EditorToolbarButton(
                    icon: "trash",
                    label: "Delete",
                    isDisabled: viewModel.selectedClipID == nil,
                    action: {
                        if let clipID = viewModel.selectedClipID {
                            viewModel.deleteClip(clipID)
                        }
                    }
                )

                Menu {
                    if let onReshoot {
                        Button("Reshoot", systemImage: "camera.fill", action: onReshoot)
                    }
                    PhotosPicker(selection: $selectedVideoItem, matching: .videos) {
                        Label("Import Video", systemImage: "film")
                    }
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        Label("Add Photo", systemImage: "photo")
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 22))
                        Text("Add")
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(Color.primary)
                    .frame(width: 64, height: bottomToolbarHeight)
                }
                .disabled(viewModel.isExporting || viewModel.isSavingToGallery)
                .onChange(of: selectedVideoItem) { _, item in
                    guard let item else { return }
                    Task {
                        await viewModel.importClip(from: item)
                        selectedVideoItem = nil
                    }
                }
                .onChange(of: selectedPhotoItem) { _, item in
                    guard let item else { return }
                    Task {
                        await viewModel.importPhoto(from: item)
                        selectedPhotoItem = nil
                    }
                }

                ForEach(EditorTool.allCases) { tool in
                    EditorToolbarButton(
                        icon: tool.iconName,
                        label: tool.title,
                        isSelected: viewModel.selectedTool == tool && presentedTool == tool,
                        isDisabled: viewModel.isExporting || viewModel.isSavingToGallery,
                        action: {
                            if presentedTool == tool {
                                activeSheet = nil
                                if tool != .text {
                                    viewModel.selectedTool = .edit
                                }
                            } else if tool == .text {
                                viewModel.beginTikTokTextEntry()
                            } else {
                                viewModel.selectedTool = tool
                                activeSheet = .tool(tool)
                            }
                        }
                    )
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: bottomToolbarHeight)
        .background(.bar)
        .disabled(viewModel.isExporting || viewModel.isSavingToGallery)
    }

    private func canSplitAtPlayhead(viewModel: EditorViewModel) -> Bool {
        guard let clip = viewModel.selectedClip ?? viewModel.project.clip(
            at: CMTime(seconds: viewModel.currentTime, preferredTimescale: 600)
        ) else { return false }
        let local = viewModel.currentTime - clip.compositionStartTime.seconds
        return local > 0.2 && (clip.scaledDuration.seconds - local) > 0.2
    }

    @ViewBuilder
    private func exportOverlay(viewModel: EditorViewModel) -> some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .contentShape(Rectangle())
            VStack(spacing: 12) {
                if viewModel.isSavingToGallery, viewModel.exportProgress >= 1 {
                    ProgressView()
                        .tint(.white)
                } else {
                    ProgressView(value: Double(viewModel.exportProgress))
                        .frame(width: 200)
                }
                Text(exportOverlayMessage(viewModel: viewModel))
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .allowsHitTesting(true)
    }

    private func exportOverlayMessage(viewModel: EditorViewModel) -> String {
        if viewModel.isSavingToGallery, viewModel.exportProgress >= 1 {
            return "Saving to Photos…"
        }
        return "Exporting… \(Int(viewModel.exportProgress * 100))%"
    }
}

private struct EditorHistorySheet: View {
    @Bindable var viewModel: EditorViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(viewModel.undoHistoryTitles.enumerated()), id: \.offset) { index, title in
                    Button(title) {
                        viewModel.jumpToHistoryStep(index: index)
                        dismiss()
                    }
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct EditorToolbarButton: View {
    let icon: String
    let label: String
    var isSelected: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.yellow : Color.primary)
            .frame(width: 64, height: 64)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(label)
    }
}

private struct EditorToolSheet: View {
    let tool: EditorTool
    @Bindable var viewModel: EditorViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch tool {
                case .edit:
                    EditToolPanel(viewModel: viewModel)
                case .audio:
                    AudioToolPanel(viewModel: viewModel)
                case .text:
                    TextToolPanel(viewModel: viewModel)
                case .subtitles:
                    SubtitleToolPanel(viewModel: viewModel)
                case .effects:
                    EffectsToolPanel(viewModel: viewModel)
                case .transform:
                    TransformToolPanel(viewModel: viewModel)
                }
            }
            .navigationTitle(tool.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .modifier(EditorToolSheetBackgroundInteraction(allowsPassthrough: tool != .text && tool != .subtitles))
    }
}

private struct EditorToolSheetBackgroundInteraction: ViewModifier {
    let allowsPassthrough: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if allowsPassthrough {
            content.presentationBackgroundInteraction(.enabled(upThrough: .medium))
        } else {
            content
        }
    }
}

private enum EditorActiveSheet: Identifiable, Equatable {
    case tool(EditorTool)
    case history
    case music
    case transition(UUID)
    case clipActions(UUID)

    var id: String {
        switch self {
        case .tool(let tool): return "tool-\(tool.rawValue)"
        case .history: return "history"
        case .music: return "music"
        case .transition(let id): return "transition-\(id.uuidString)"
        case .clipActions(let id): return "clipActions-\(id.uuidString)"
        }
    }
}

/// Observes ViewModel triggers and routes them to `activeSheet`. Non-generic to keep the type-checker fast.
private struct EditorSheetObserver: ViewModifier {
    @Binding var activeSheet: EditorActiveSheet?
    var viewModel: EditorViewModel?
    var onChange: (EditorActiveSheet?, EditorActiveSheet?) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: activeSheet) { oldSheet, sheet in
                onChange(oldSheet, sheet)
            }
            .onChange(of: viewModel?.pendingToolPresentation) { _, tool in
                guard let tool else { return }
                if tool == .text {
                    viewModel?.prepareForTextToolPresentation()
                }
                activeSheet = .tool(tool)
                viewModel?.pendingToolPresentation = nil
            }
            .onChange(of: viewModel?.showHistorySheet) { _, show in
                if show == true {
                    activeSheet = .history
                } else if case .history = activeSheet {
                    activeSheet = nil
                }
            }
            .onChange(of: viewModel?.pendingMusicPicker) { _, show in
                guard show == true else { return }
                activeSheet = .music
                viewModel?.pendingMusicPicker = false
            }
            .onChange(of: viewModel?.pendingTransitionClipID) { _, clipID in
                guard let clipID else { return }
                activeSheet = .transition(clipID)
                viewModel?.pendingTransitionClipID = nil
            }
            .onChange(of: viewModel?.pendingClipActionsClipID) { _, clipID in
                guard let clipID else { return }
                activeSheet = .clipActions(clipID)
                viewModel?.pendingClipActionsClipID = nil
            }
    }
}

/// Self-contained resize zone — owns `timelineFraction` as its own `@State` so that
/// dragging the resize handle only re-evaluates THIS view's body, not the entire
/// `EditorView.body` (which carries sheet observers, alerts, tasks, etc.).
struct EditorResizableZone: View {
    @Bindable var viewModel: EditorViewModel
    @Binding var isFullscreenPresented: Bool
    var allowOverlayPlacement: Bool = true

    @State private var timelineFraction: CGFloat = 0.30
    /// Passed into `TimelineView` only when resize ends — avoids 60fps snapshot rebuilds mid-drag.
    @State private var committedTimelineHeight: CGFloat = 200
    @StateObject private var zoneResizeSession = ZoneResizeSession()

    private let resizeHandleHeight: CGFloat = 44
    private let minTimelineFraction: CGFloat = 0.16
    private let maxTimelineFraction: CGFloat = 0.52

    var body: some View {
        GeometryReader { geo in
            let resizableHeight = max(geo.size.height - resizeHandleHeight, 200)
            let timelineHeight = resizableHeight * timelineFraction
            let previewHeight = resizableHeight - timelineHeight

            VStack(spacing: 0) {
                previewSection
                    .frame(height: max(previewHeight, 120))

                EditorZoneResizeHandle(
                    timelineFraction: $timelineFraction,
                    session: zoneResizeSession,
                    workspaceHeight: resizableHeight,
                    minFraction: minTimelineFraction,
                    maxFraction: maxTimelineFraction
                )
                .opacity(viewModel.isTextInputActive ? 0 : 1)
                .allowsHitTesting(!viewModel.isTextInputActive)

                TimelineView(
                    viewModel: viewModel,
                    maxScrollHeight: committedTimelineHeight
                )
                .frame(height: timelineHeight)
                .padding(.horizontal, 6)
                .opacity(viewModel.isTextInputActive ? 0 : 1)
                .allowsHitTesting(!viewModel.isTextInputActive)
            }
            .onAppear {
                committedTimelineHeight = timelineHeight
            }
            .onChange(of: geo.size.height) { _, _ in
                if !zoneResizeSession.isResizeActive {
                    committedTimelineHeight = timelineHeight
                }
            }
            .onChange(of: zoneResizeSession.isResizeActive) { _, isActive in
                if !isActive {
                    committedTimelineHeight = timelineHeight
                }
            }
        }
        .ignoresSafeArea(.keyboard, edges: .all)
    }

    @ViewBuilder
    private var previewSection: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(white: 0.08))

                Color.black
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)
                    .overlay {
                        ZStack {
                            if viewModel.isPreviewDetached {
                                EditorHoldFrameView(image: viewModel.previewHoldFrame)
                            } else {
                                EditorPreviewPlayer(
                                    player: viewModel.player,
                                    holdFrame: viewModel.previewHoldFrame,
                                    videoGravity: .resizeAspectFill
                                )
                            }

                            EditorOverlayCanvasView(
                                viewModel: viewModel,
                                allowPlacement: allowOverlayPlacement
                            )
                                .allowsHitTesting(
                                    viewModel.selectedTool != .transform && (
                                        viewModel.selectedTool == .text
                                        || viewModel.selectedTextID != nil
                                        || viewModel.selectedStickerID != nil
                                        || viewModel.inlineEditingTextID != nil
                                        || viewModel.hasVisibleOverlaysAtPlayhead
                                    )
                                )

                            if viewModel.selectedTool == .transform {
                                EditorTransformPreviewOverlay(viewModel: viewModel)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(6)

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.red.opacity(0.85), in: Capsule())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            EditorPreviewTransportBar(viewModel: viewModel) {
                isFullscreenPresented = true
            }
            .padding(.horizontal, 10)
            .opacity(viewModel.isTextInputActive ? 0 : 1)
            .allowsHitTesting(!viewModel.isTextInputActive)
        }
        .padding(.bottom, 4)
    }
}
