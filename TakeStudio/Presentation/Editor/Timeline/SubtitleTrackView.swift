import AVFoundation
import SwiftUI

struct SubtitleTrackView: View {
    let segments: [SubtitleSegment]
    let pixelsPerSecond: CGFloat
    let selectedID: UUID?
    let onSelect: (UUID) -> Void
    let onTimingPreview: (SubtitleSegment) -> Void
    let onTimingCommit: (SubtitleSegment) -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(segments) { segment in
                let x = CGFloat(segment.timeRange.start.seconds) * pixelsPerSecond
                let width = max(CGFloat(segment.timeRange.duration.seconds) * pixelsPerSecond, 40)

                Text(segment.text)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .frame(width: width, height: 28)
                    .background(
                        selectedID == segment.id ? Color.cyan.opacity(0.7) : Color.blue.opacity(0.55),
                        in: Capsule()
                    )
                    .offset(x: x, y: 8)
                    .onTapGesture { onSelect(segment.id) }
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let delta = Double(value.translation.width / pixelsPerSecond)
                                var updated = segment
                                let newStart = CMTime(seconds: segment.timeRange.start.seconds + delta, preferredTimescale: 600)
                                updated.timeRange = CMTimeRange(start: newStart, duration: segment.timeRange.duration)
                                onTimingPreview(updated)
                            }
                            .onEnded { value in
                                let delta = Double(value.translation.width / pixelsPerSecond)
                                var updated = segment
                                let newStart = CMTime(seconds: segment.timeRange.start.seconds + delta, preferredTimescale: 600)
                                updated.timeRange = CMTimeRange(start: newStart, duration: segment.timeRange.duration)
                                onTimingCommit(updated)
                            }
                    )
            }
        }
    }
}

struct TextOverlayTrackView: View {
    let overlays: [TextOverlay]
    let pixelsPerSecond: CGFloat
    let onSelect: (UUID) -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(overlays) { overlay in
                let x = CGFloat(overlay.timeRange.start.seconds) * pixelsPerSecond
                let width = max(CGFloat(overlay.timeRange.duration.seconds) * pixelsPerSecond, 36)

                Text(overlay.text)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .frame(width: width, height: 28)
                    .background(Color.purple.opacity(0.55), in: Capsule())
                    .offset(x: x, y: 8)
                    .onTapGesture { onSelect(overlay.id) }
            }
        }
    }
}

struct StickerOverlayTrackView: View {
    let overlays: [StickerOverlay]
    let pixelsPerSecond: CGFloat
    let onSelect: (UUID) -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(overlays) { overlay in
                let x = CGFloat(overlay.timeRange.start.seconds) * pixelsPerSecond
                let width = max(CGFloat(overlay.timeRange.duration.seconds) * pixelsPerSecond, 36)

                Text(overlay.emoji ?? "🖼")
                    .font(.system(size: 14))
                    .frame(width: width, height: 28)
                    .background(Color.orange.opacity(0.45), in: Capsule())
                    .offset(x: x, y: 8)
                    .onTapGesture { onSelect(overlay.id) }
            }
        }
    }
}
