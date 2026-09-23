import AVFoundation
import SwiftUI
import UIKit

/// Legacy SwiftUI video track — timeline editor uses UIKit `TimelineClipCell` filmstrip.
struct VideoTrackView: View {
    let clips: [VideoClip]
    let pixelsPerSecond: CGFloat
    let selectedClipID: UUID?
    let draggingClipIndex: Int?
    let clipDragTranslation: CGFloat
    let waveformStore: WaveformStore
    let onSelectClip: (UUID) -> Void
    let onTrimPreview: (UUID, CMTimeRange) -> Void
    let onTrimCommit: (UUID, CMTimeRange) -> Void
    let onToggleMute: (UUID) -> Void
    var onTransitionTap: ((UUID) -> Void)?

    private let transitionWidth: CGFloat = 24

    private var hasAnyAttachedAudio: Bool {
        clips.contains { !$0.isMuted && !$0.hasDetachedAudio }
    }

    private var contentHeight: CGFloat {
        hasAnyAttachedAudio ? 72 : 44
    }

    private var waveformTaskID: String {
        clips.map { "\($0.id)-\($0.timeRange.start.seconds)-\($0.timeRange.duration.seconds)" }.joined(separator: "|")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                if index > 0 {
                    transitionHandle(after: clips[index - 1])
                }

                VideoClipCellView(
                    clip: clip,
                    pixelsPerSecond: pixelsPerSecond,
                    isSelected: selectedClipID == clip.id,
                    isDragging: draggingClipIndex == index,
                    waveformSample: waveformStore.sample(for: clip.sourceURL),
                    showAudioSubRow: !clip.isMuted && !clip.hasDetachedAudio,
                    onSelect: { onSelectClip(clip.id) },
                    onTrimPreview: { onTrimPreview(clip.id, $0) },
                    onTrimCommit: { onTrimCommit(clip.id, $0) },
                    onToggleMute: { onToggleMute(clip.id) }
                )
                .offset(x: draggingClipIndex == index ? clipDragTranslation : 0)
                .zIndex(draggingClipIndex == index ? 1 : 0)
            }
        }
        .frame(height: contentHeight, alignment: .top)
        .task(id: waveformTaskID) {
            await loadWaveformSamples()
        }
    }

    @ViewBuilder
    private func transitionHandle(after clip: VideoClip) -> some View {
        let hasTransition = clip.transition != nil && clip.transition != .cut
        Button {
            onTransitionTap?(clip.id)
        } label: {
            Image(systemName: "hexagon")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hasTransition ? Color.yellow : Color.white.opacity(0.45))
                .frame(width: transitionWidth, height: contentHeight)
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(hasTransition ? Color.yellow : Color.white.opacity(0.25), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    private func clipWidth(_ clip: VideoClip) -> CGFloat {
        max(CGFloat(clip.scaledDuration.seconds) * pixelsPerSecond, 1)
    }

    private func loadWaveformSamples() async {
        for clip in clips where !clip.hasDetachedAudio {
            await waveformStore.loadIfNeeded(for: clip.sourceURL)
        }
    }
}

private struct VideoClipCellView: View {
    let clip: VideoClip
    let pixelsPerSecond: CGFloat
    let isSelected: Bool
    let isDragging: Bool
    let waveformSample: WaveformSample?
    let showAudioSubRow: Bool
    let onSelect: () -> Void
    let onTrimPreview: (CMTimeRange) -> Void
    let onTrimCommit: (CMTimeRange) -> Void
    let onToggleMute: () -> Void

    @State private var previewTimeRange: CMTimeRange?
    @State private var trimAnchor: CMTimeRange?

    private var activeTimeRange: CMTimeRange {
        previewTimeRange ?? clip.timeRange
    }

    private var width: CGFloat {
        max(CGFloat(clip.scaledDuration.seconds) * pixelsPerSecond, 1)
    }

    private var cellHeight: CGFloat {
        showAudioSubRow ? 72 : 44
    }

    var body: some View {
        VStack(spacing: 0) {
            videoFilmstripRow
            if showAudioSubRow {
                audioSubRow
            }
        }
        .frame(width: width, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        }
        .overlay {
            if isSelected {
                HStack(spacing: 0) {
                    trimHandle(isStart: true)
                    Spacer(minLength: 0)
                    trimHandle(isStart: false)
                }
                .frame(width: width, height: cellHeight)
            }
        }
        .scaleEffect(isDragging ? 1.05 : 1)
        .opacity(isDragging ? 0.9 : 1)
        .shadow(color: isDragging ? .black.opacity(0.45) : .clear, radius: isDragging ? 8 : 0)
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isDragging)
        .onChange(of: clip.timeRange) { _, _ in
            previewTimeRange = nil
        }
    }

    private var videoFilmstripRow: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.35))
                .frame(width: width, height: 44)
        }
        .frame(width: width, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.yellow, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    private var audioSubRow: some View {
        HStack(spacing: 0) {
            Button(action: onToggleMute) {
                Image(systemName: clip.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(clip.isMuted ? Color.secondary : Color.teal)
                    .frame(width: 24, height: 28)
            }
            .buttonStyle(.plain)

            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.black.opacity(0.35))

                WaveformStripView(
                    sample: waveformSample,
                    width: width - 24,
                    height: 28
                )
            }
            .frame(height: 28)
        }
        .frame(width: width, height: 28)
        .overlay {
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func trimHandle(isStart: Bool) -> some View {
        ZStack {
            Color.yellow
            Image(systemName: isStart ? "chevron.left" : "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.black)
        }
        .frame(width: 24, height: cellHeight)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: isStart ? 4 : 0,
                bottomLeadingRadius: isStart ? 4 : 0,
                bottomTrailingRadius: isStart ? 0 : 4,
                topTrailingRadius: isStart ? 0 : 4,
                style: .continuous
            )
        )
        .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if trimAnchor == nil {
                            trimAnchor = previewTimeRange ?? clip.timeRange
                        }
                        guard let anchor = trimAnchor else { return }
                        let newRange: CMTimeRange?
                        if isStart {
                            newRange = clip.startTrimmed(
                                timelineDelta: value.translation.width,
                                pixelsPerSecond: pixelsPerSecond,
                                anchor: anchor
                            )
                        } else {
                            newRange = clip.endTrimmed(
                                timelineDelta: value.translation.width,
                                pixelsPerSecond: pixelsPerSecond,
                                anchor: anchor
                            )
                        }
                        guard let newRange else { return }
                        previewTimeRange = newRange
                        onTrimPreview(newRange)
                    }
                    .onEnded { _ in
                        if let previewTimeRange {
                            onTrimCommit(previewTimeRange)
                        }
                        previewTimeRange = nil
                        trimAnchor = nil
                    }
            )
    }
}
