import AVFoundation
import SwiftUI
import UIKit

struct TimelineView: View {
    @Bindable var viewModel: EditorViewModel
    var maxScrollHeight: CGFloat = 140

    @State private var scrollOffset: CGFloat = 0
    @State private var draggingLayer: VisualLayer?
    @State private var layerDragTranslation: CGFloat = 0
    @State private var layerInsertionIndex: Int?
    @State private var draggingClipIndex: Int?
    @State private var clipDragTranslation: CGFloat = 0

    private let trackRowHeight: CGFloat = 44
    private let trackSpacing: CGFloat = 6
    private let trackLabelWidth: CGFloat = 40
    private let rulerHeight: CGFloat = 20

    private var videoTrackVerticalRange: (minY: CGFloat, maxY: CGFloat) {
        var y: CGFloat = rulerHeight
        for layer in visibleVisualLayers {
            let height = layer == .video ? videoTrackContentHeight : trackRowHeight
            if layer == .video {
                return (y, y + height)
            }
            y += height + trackSpacing
        }
        return (rulerHeight, rulerHeight + videoTrackContentHeight)
    }

    private var clipLayouts: [TimelineClipLayout] {
        let yRange = videoTrackVerticalRange
        var x: CGFloat = 0
        return viewModel.timelineClips().enumerated().map { index, clip in
            let width = max(CGFloat(clip.scaledDuration.seconds) * viewModel.pixelsPerSecond, 1)
            let layout = TimelineClipLayout(
                index: index,
                clipID: clip.id,
                minX: x,
                maxX: x + width,
                minY: yRange.minY,
                maxY: yRange.maxY
            )
            x += width
            return layout
        }
    }

    private var contentWidth: CGFloat {
        var x: CGFloat = 0
        for clip in viewModel.timelineClips() {
            x += max(CGFloat(clip.scaledDuration.seconds) * viewModel.pixelsPerSecond, 1)
        }
        guard x > 0 else { return 300 }
        return min(x, EditorTimelineConstants.maxContentWidth)
    }

    private var detachedTracks: [AudioTrack] {
        viewModel.project.audioTracks.filter { $0.kind == .detached || $0.isDetachedFromVideo }
    }

    private var musicTracks: [AudioTrack] {
        viewModel.project.audioTracks.filter { $0.kind == .music }
    }

    private var sfxTracks: [AudioTrack] {
        viewModel.project.audioTracks.filter { $0.kind == .sfx }
    }

    private var hasVoiceover: Bool {
        !(viewModel.project.voiceoverTrack?.segments.isEmpty ?? true)
    }

    private var hasSubtitles: Bool {
        !(viewModel.project.subtitleTrack?.segments.isEmpty ?? true)
    }

    private var hasTextOverlays: Bool {
        !viewModel.project.textOverlays.isEmpty
    }

    private var hasStickers: Bool {
        !viewModel.project.stickerOverlays.isEmpty
    }

    private var videoTrackContentHeight: CGFloat {
        viewModel.project.clips.contains { !$0.isMuted && !$0.hasDetachedAudio } ? 72 : 44
    }

    private var visibleVisualLayers: [VisualLayer] {
        viewModel.project.layerOrder.filter { layer in
            switch layer {
            case .video: return true
            case .subtitles: return hasSubtitles
            case .textOverlays: return hasTextOverlays
            case .stickers: return hasStickers
            }
        }
    }

    private var visibleAudioTrackCount: Int {
        var count = 0
        if !detachedTracks.isEmpty { count += 1 }
        if !musicTracks.isEmpty { count += 1 }
        if !sfxTracks.isEmpty { count += 1 }
        if hasVoiceover { count += 1 }
        return count
    }

    private var trackStackHeight: CGFloat {
        var height: CGFloat = 0
        var rowCount = 0
        for layer in visibleVisualLayers {
            height += layer == .video ? videoTrackContentHeight : trackRowHeight
            rowCount += 1
        }
        if visibleAudioTrackCount > 0 {
            height += trackSpacing + 1
            height += CGFloat(visibleAudioTrackCount) * trackRowHeight
            rowCount += visibleAudioTrackCount
        }
        if rowCount > 1 {
            height += CGFloat(rowCount - 1) * trackSpacing
        }
        return height
    }

    private var scrollContentHeight: CGFloat {
        rulerHeight + trackStackHeight
    }

    private var scrollAreaHeight: CGFloat {
        max(maxScrollHeight, 44)
    }

    /// Fills the montage workspace between ruler and toolbar when tracks are shorter than the panel.
    private var timelineContentHeight: CGFloat {
        max(scrollContentHeight, scrollAreaHeight)
    }

    private var rulerInterval: TimeInterval {
        if viewModel.pixelsPerSecond > 90 { return 1 }
        if viewModel.pixelsPerSecond > 45 { return 3 }
        return 5
    }

    private var rulerTickCount: Int {
        guard viewModel.totalDuration > 0 else { return 1 }
        return Int(ceil(viewModel.totalDuration / rulerInterval)) + 1
    }

    var body: some View {
        // Always use the same view structure — never switch between ScrollView and
        // another container based on height, because that would destroy and recreate
        // the entire TimelineScrollCoordinator (UIScrollView + cells + gestures) every
        // frame during resize, freezing the editor.
        ScrollView(.vertical, showsIndicators: false) {
            timelineWorkspace
        }
        .frame(height: scrollAreaHeight, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            GeometryReader { geo in
                Color(white: 0.06)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onAppear {
                        applyFitToWidth(containerWidth: geo.size.width)
                    }
                    .onChange(of: geo.size.width) { _, width in
                        applyFitToWidth(containerWidth: width)
                    }
            }
        }
        .task { await loadWaveformSamples() }
        .onChange(of: viewModel.project.audioTracks.count) { _, _ in
            Task { await loadWaveformSamples() }
        }
    }

    private var timelineScrollSnapshot: TimelineScrollSnapshot {
        TimelineScrollSnapshot(
            renderSnapshot: timelineRenderSnapshot,
            playbackTime: viewModel.displayCurrentTime,
            totalDuration: viewModel.displayTotalDuration,
            waveformSamples: waveformSamplesMap,
            trimVisualSettleToken: viewModel.trimVisualSettleToken
        )
    }

    private var timelineRenderSnapshot: TimelineRenderSnapshot {
        TimelineRenderSnapshot(
            clips: viewModel.timelineClips(),
            pixelsPerSecond: viewModel.pixelsPerSecond,
            contentWidth: contentWidth,
            contentHeight: timelineContentHeight,
            rulerHeight: rulerHeight,
            trackSpacing: trackSpacing,
            trackRowHeight: trackRowHeight,
            videoTrackContentHeight: videoTrackContentHeight,
            selectedClipID: viewModel.selectedClipID,
            selectedSubtitleID: viewModel.selectedSubtitleID,
            selectedTextID: viewModel.selectedTextID,
            selectedStickerID: viewModel.selectedStickerID,
            visibleVisualLayers: visibleVisualLayers,
            detachedTracks: detachedTracks,
            musicTracks: musicTracks,
            sfxTracks: sfxTracks,
            voiceoverSegments: viewModel.project.voiceoverTrack?.segments ?? [],
            subtitleSegments: viewModel.project.subtitleTrack?.segments ?? [],
            textOverlays: viewModel.project.textOverlays,
            stickerOverlays: viewModel.project.stickerOverlays,
            clipLayouts: clipLayouts,
            totalDuration: viewModel.totalDuration,
            draggingClipIndex: draggingClipIndex,
            clipDragTranslation: clipDragTranslation,
            rulerInterval: rulerInterval,
            rulerSubInterval: rulerSubInterval,
            isClipTrimming: viewModel.isClipTrimming
        )
    }

    private var waveformSamplesMap: [String: [Float]] {
        var map: [String: [Float]] = [:]
        for clip in viewModel.project.clips where !clip.hasDetachedAudio {
            if let sample = viewModel.waveformStore.sample(for: clip.sourceURL) {
                map[clip.sourceURL.path] = sample.samples
            }
        }
        for track in viewModel.project.audioTracks {
            if let sample = viewModel.waveformStore.sample(for: track.sourceURL) {
                map[track.sourceURL.path] = sample.samples
            }
        }
        return map
    }

    private func applyFitToWidth(containerWidth: CGFloat) {
        let width = max(containerWidth - trackLabelWidth - 6, 100)
        Task { @MainActor in
            viewModel.fitTimelineToWidth(availableWidth: width)
        }
    }

    @ViewBuilder
    private var timelineWorkspace: some View {
        HStack(alignment: .top, spacing: 6) {
            trackLabelsColumn

            ZStack(alignment: .top) {
                TimelineScrollCoordinator(
                    snapshot: timelineScrollSnapshot,
                    scrollOffset: $scrollOffset,
                    pixelsPerSecond: $viewModel.pixelsPerSecond,
                    draggingClipIndex: $draggingClipIndex,
                    clipDragTranslation: $clipDragTranslation,
                    onScroll: { time in
                        viewModel.seek(to: time)
                    },
                    onClipDragEnded: { from, to in
                        viewModel.moveClip(from: from, to: to)
                    },
                    onClipContextMenu: { clipID in
                        viewModel.selectedClipID = clipID
                        viewModel.pendingClipActionsClipID = clipID
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    },
                    onSelectClip: { clipID in
                        viewModel.selectedClipID = clipID
                    },
                    onTrimBegin: {
                        viewModel.beginClipTrim()
                    },
                    onTrimPreview: { id, range in
                        viewModel.previewClipTrim(clipID: id, timeRange: range)
                    },
                    onTrimCommit: { id, range in
                        viewModel.commitClipTrim(clipID: id, timeRange: range)
                    },
                    onTrimCancel: {
                        viewModel.cancelClipTrim()
                    },
                    onTrimEnd: {
                        // Scrubber unfreezes after playback seek settles in commitClipTrim.
                    },
                    onToggleMute: { viewModel.toggleClipMute(clipID: $0) },
                    onTransitionTap: { clipID in
                        viewModel.pendingTransitionClipID = clipID
                    },
                    onSelectSubtitle: { viewModel.selectedSubtitleID = $0 },
                    onSelectText: { viewModel.selectedTextID = $0 },
                    onSelectSticker: { viewModel.selectedStickerID = $0 },
                    onSelectAudio: { viewModel.selectedAudioTrackID = $0 }
                )
                .frame(height: scrollAreaHeight, alignment: .top)
            }
        }
        .frame(height: scrollAreaHeight, alignment: .top)
    }

    @ViewBuilder
    private var trackLabelsColumn: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(width: trackLabelWidth, height: rulerHeight)

            VStack(spacing: trackSpacing) {
                ForEach(visibleVisualLayers) { layer in
                    trackLabel(for: layer)
                }

                if visibleAudioTrackCount > 0 {
                    audioTrackLabelsGroup
                }
            }

            Spacer(minLength: 0)
        }
        .frame(width: trackLabelWidth, height: scrollAreaHeight, alignment: .top)
    }

    @ViewBuilder
    private func trackLabel(for layer: VisualLayer) -> some View {
        let layerIndex = visibleVisualLayers.firstIndex(of: layer) ?? 0
        let isDragging = draggingLayer == layer

        TrackLabelView(
            icon: layer.icon,
            title: layer.title,
            systemImage: layer.systemImage,
            contentHeight: layer == .video ? videoTrackContentHeight : trackRowHeight,
            isDraggable: layer != .video,
            isDragging: isDragging,
            onLift: { beginLayerDrag(layer) },
            onDrag: { translation in
                layerDragTranslation = translation
                layerInsertionIndex = targetLayerInsertion(for: layer, translation: translation)
            },
            onRelease: { finishLayerDrag(layer) }
        )
        .offset(y: isDragging ? layerDragTranslation : 0)
        .overlay(alignment: .top) {
            if layerInsertionIndex == layerIndex, draggingLayer != nil {
                Rectangle()
                    .fill(Color.primary.opacity(0.5))
                    .frame(height: 2)
            }
        }
    }

    @ViewBuilder
    private var audioTrackLabelsGroup: some View {
        VStack(spacing: trackSpacing) {
            Color.clear
                .frame(height: 1)

            if !detachedTracks.isEmpty {
                TrackLabelView(
                    icon: EditorTimelineTrack.detachedAudio.icon,
                    title: EditorTimelineTrack.detachedAudio.title,
                    systemImage: EditorTimelineTrack.detachedAudio.systemImage,
                    contentHeight: trackRowHeight
                )
            }

            if !musicTracks.isEmpty {
                TrackLabelView(
                    icon: EditorTimelineTrack.music.icon,
                    title: EditorTimelineTrack.music.title,
                    systemImage: EditorTimelineTrack.music.systemImage,
                    contentHeight: trackRowHeight
                )
            }

            if hasVoiceover {
                TrackLabelView(
                    icon: EditorTimelineTrack.voiceover.icon,
                    title: EditorTimelineTrack.voiceover.title,
                    systemImage: EditorTimelineTrack.voiceover.systemImage,
                    contentHeight: trackRowHeight
                )
            }
        }
    }

    private func beginLayerDrag(_ layer: VisualLayer) {
        draggingLayer = layer
        layerDragTranslation = 0
        layerInsertionIndex = visibleVisualLayers.firstIndex(of: layer)
    }

    private func targetLayerInsertion(for layer: VisualLayer, translation: CGFloat) -> Int {
        guard let sourceIndex = visibleVisualLayers.firstIndex(of: layer) else { return 0 }
        let rowHeight = trackRowHeight + trackSpacing
        let delta = Int((translation / rowHeight).rounded())
        let target = min(max(sourceIndex + delta, 0), visibleVisualLayers.count - 1)
        if visibleVisualLayers[target] == .video, target > sourceIndex {
            return max(0, target - 1)
        }
        return target
    }

    private func finishLayerDrag(_ layer: VisualLayer) {
        guard let sourceIndex = viewModel.project.layerOrder.firstIndex(of: layer),
              let visibleSource = visibleVisualLayers.firstIndex(of: layer),
              let visibleDest = layerInsertionIndex else {
            draggingLayer = nil
            layerDragTranslation = 0
            layerInsertionIndex = nil
            return
        }
        if visibleSource != visibleDest {
            let destLayer = visibleVisualLayers[visibleDest]
            if let destIndex = viewModel.project.layerOrder.firstIndex(of: destLayer) {
                viewModel.moveLayer(from: sourceIndex, to: destIndex)
            }
        }
        draggingLayer = nil
        layerDragTranslation = 0
        layerInsertionIndex = nil
    }

    private var rulerSubInterval: TimeInterval {
        switch rulerInterval {
        case 5...: return 1
        case 3..<5: return 1
        default: return 0.5
        }
    }

    private func loadWaveformSamples() async {
        for clip in viewModel.project.clips where !clip.hasDetachedAudio {
            await viewModel.waveformStore.loadIfNeeded(for: clip.sourceURL)
        }
        for track in viewModel.project.audioTracks {
            await viewModel.waveformStore.loadIfNeeded(for: track.sourceURL)
        }
    }
}

struct EditorClipActionsSheet: View {
    let clip: VideoClip
    @Bindable var viewModel: EditorViewModel
    let onDismiss: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button {
                    Task { await viewModel.splitClip(at: viewModel.currentTime) }
                    close()
                } label: {
                    Label("Split at Playhead", systemImage: "scissors")
                }

                if !clip.hasDetachedAudio {
                    Button {
                        viewModel.detachAudio(from: clip.id)
                        close()
                    } label: {
                        Label("Detach Audio", systemImage: "speaker.wave.2")
                    }
                }

                Button {
                    // Only flag the panel; sheet observer presents `.tool(.edit)` after dismiss.
                    viewModel.showSpeedPanel = true
                    close()
                } label: {
                    Label("Change Speed", systemImage: "speedometer")
                }

                Button {
                    Task { await viewModel.reverseSelectedClip() }
                    close()
                } label: {
                    Label("Reverse", systemImage: "arrow.uturn.backward")
                }

                Button(role: .destructive) {
                    viewModel.deleteClip(clip.id)
                    close()
                } label: {
                    Label("Delete Clip", systemImage: "trash")
                }
            }
            .navigationTitle("Clip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { close() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func close() {
        onDismiss()
        dismiss()
    }
}
