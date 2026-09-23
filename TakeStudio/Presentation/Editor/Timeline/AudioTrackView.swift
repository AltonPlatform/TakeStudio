import AVFoundation
import SwiftUI

struct AudioTrackView: View {
    let track: AudioTrack?
    let segments: [VoiceoverSegment]
    let pixelsPerSecond: CGFloat
    let totalDuration: TimeInterval
    let waveformSample: WaveformSample?
    let tint: Color
    var onReattach: ((UUID) -> Void)?
    var onDeleteTrack: ((UUID) -> Void)?
    var onTrackTimingPreview: ((AudioTrack) -> Void)?
    var onTrackTimingCommit: ((AudioTrack) -> Void)?
    var onSegmentTimingPreview: ((VoiceoverSegment) -> Void)?
    var onSegmentTimingCommit: ((VoiceoverSegment) -> Void)?
    var clipBoundaries: [TimeInterval] = []
    var playheadTime: TimeInterval = 0
    var onSnap: (() -> Void)?

    var body: some View {
        ZStack(alignment: .leading) {
            if let track {
                draggableSegment(
                    start: track.startTime.seconds,
                    duration: track.timeRange.duration.seconds,
                    label: track.title,
                    track: track
                )
            }

            ForEach(segments) { segment in
                draggableSegment(
                    start: segment.startTime.seconds,
                    duration: segment.duration.seconds,
                    label: "VO",
                    segment: segment
                )
            }

            if waveformSample != nil {
                WaveformStripView(
                    sample: waveformSample,
                    width: max(CGFloat(totalDuration) * pixelsPerSecond, 1),
                    height: 44,
                    color: tint,
                    opacity: 0.35
                )
                .allowsHitTesting(false)
            }
        }
        .frame(width: max(CGFloat(totalDuration) * pixelsPerSecond, 1), height: 44, alignment: .leading)
    }

    @ViewBuilder
    private func draggableSegment(
        start: TimeInterval,
        duration: TimeInterval,
        label: String,
        track: AudioTrack? = nil,
        segment: VoiceoverSegment? = nil
    ) -> some View {
        let x = CGFloat(start) * pixelsPerSecond
        let width = max(CGFloat(duration) * pixelsPerSecond, 24)
        let isDetached = track?.isDetachedFromVideo == true || track?.kind == .detached

        RoundedRectangle(cornerRadius: 4)
            .fill(tint.opacity(0.55))
            .frame(width: width, height: 36)
            .overlay {
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .offset(x: x, y: 4)
            .contextMenu {
                if isDetached, let track {
                    Button {
                        onReattach?(track.id)
                    } label: {
                        Label("Re-attach to video", systemImage: "link")
                    }
                    Button(role: .destructive) {
                        onDeleteTrack?(track.id)
                    } label: {
                        Label("Delete audio track", systemImage: "trash")
                    }
                }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let rawStart = max(0, start + Double(value.translation.width / pixelsPerSecond))
                        let snapped = snapTime(rawStart)
                        if var segment {
                            segment.startTime = CMTime(seconds: snapped, preferredTimescale: 600)
                            onSegmentTimingPreview?(segment)
                        } else if var track {
                            track.startTime = CMTime(seconds: snapped, preferredTimescale: 600)
                            onTrackTimingPreview?(track)
                        }
                    }
                    .onEnded { value in
                        let rawStart = max(0, start + Double(value.translation.width / pixelsPerSecond))
                        let snapped = snapTime(rawStart)
                        if var segment {
                            segment.startTime = CMTime(seconds: snapped, preferredTimescale: 600)
                            onSegmentTimingCommit?(segment)
                        } else if var track {
                            track.startTime = CMTime(seconds: snapped, preferredTimescale: 600)
                            onTrackTimingCommit?(track)
                        }
                    }
            )
    }

    private func snapTime(_ time: TimeInterval) -> TimeInterval {
        let tolerance = Double(8 / pixelsPerSecond)
        let candidates: [TimeInterval] = [0, playheadTime] + clipBoundaries
        for candidate in candidates {
            if abs(time - candidate) <= tolerance {
                onSnap?()
                return candidate
            }
        }
        return time
    }
}
