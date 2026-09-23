import AVFoundation
import CoreGraphics
import Foundation

struct TimelineRenderSnapshot: Equatable {
    let clips: [VideoClip]
    let pixelsPerSecond: CGFloat
    let contentWidth: CGFloat
    let contentHeight: CGFloat
    let rulerHeight: CGFloat
    let trackSpacing: CGFloat
    let trackRowHeight: CGFloat
    let videoTrackContentHeight: CGFloat
    let selectedClipID: UUID?
    let selectedSubtitleID: UUID?
    let selectedTextID: UUID?
    let selectedStickerID: UUID?
    let visibleVisualLayers: [VisualLayer]
    let detachedTracks: [AudioTrack]
    let musicTracks: [AudioTrack]
    let sfxTracks: [AudioTrack]
    let voiceoverSegments: [VoiceoverSegment]
    let subtitleSegments: [SubtitleSegment]
    let textOverlays: [TextOverlay]
    let stickerOverlays: [StickerOverlay]
    let clipLayouts: [TimelineClipLayout]
    let totalDuration: TimeInterval
    let draggingClipIndex: Int?
    let clipDragTranslation: CGFloat
    let rulerInterval: TimeInterval
    let rulerSubInterval: TimeInterval
    let isClipTrimming: Bool

    static let transitionWidth: CGFloat = 24

    /// Layout equality ignores text overlay string content so typing doesn't
    /// force a full UIKit timeline relayout on every keystroke.
    static func == (lhs: TimelineRenderSnapshot, rhs: TimelineRenderSnapshot) -> Bool {
        lhs.clips == rhs.clips
            && lhs.pixelsPerSecond == rhs.pixelsPerSecond
            && lhs.contentWidth == rhs.contentWidth
            && lhs.contentHeight == rhs.contentHeight
            && lhs.rulerHeight == rhs.rulerHeight
            && lhs.trackSpacing == rhs.trackSpacing
            && lhs.trackRowHeight == rhs.trackRowHeight
            && lhs.videoTrackContentHeight == rhs.videoTrackContentHeight
            && lhs.selectedClipID == rhs.selectedClipID
            && lhs.selectedSubtitleID == rhs.selectedSubtitleID
            && lhs.selectedTextID == rhs.selectedTextID
            && lhs.selectedStickerID == rhs.selectedStickerID
            && lhs.visibleVisualLayers == rhs.visibleVisualLayers
            && lhs.detachedTracks == rhs.detachedTracks
            && lhs.musicTracks == rhs.musicTracks
            && lhs.sfxTracks == rhs.sfxTracks
            && lhs.voiceoverSegments == rhs.voiceoverSegments
            && lhs.subtitleSegments == rhs.subtitleSegments
            && textOverlaysLayoutEqual(lhs.textOverlays, rhs.textOverlays)
            && lhs.stickerOverlays == rhs.stickerOverlays
            && lhs.clipLayouts == rhs.clipLayouts
            && lhs.totalDuration == rhs.totalDuration
            && lhs.draggingClipIndex == rhs.draggingClipIndex
            && lhs.clipDragTranslation == rhs.clipDragTranslation
            && lhs.rulerInterval == rhs.rulerInterval
            && lhs.rulerSubInterval == rhs.rulerSubInterval
            && lhs.isClipTrimming == rhs.isClipTrimming
    }

    /// Equality ignoring `contentHeight` — used to skip the expensive cell relayout
    /// when only the container height changed (e.g. during preview/timeline resize).
    static func layoutEqual(lhs: TimelineRenderSnapshot, rhs: TimelineRenderSnapshot) -> Bool {
        lhs.clips == rhs.clips
            && lhs.pixelsPerSecond == rhs.pixelsPerSecond
            && lhs.contentWidth == rhs.contentWidth
            && lhs.rulerHeight == rhs.rulerHeight
            && lhs.trackSpacing == rhs.trackSpacing
            && lhs.trackRowHeight == rhs.trackRowHeight
            && lhs.videoTrackContentHeight == rhs.videoTrackContentHeight
            && lhs.selectedClipID == rhs.selectedClipID
            && lhs.selectedSubtitleID == rhs.selectedSubtitleID
            && lhs.selectedTextID == rhs.selectedTextID
            && lhs.selectedStickerID == rhs.selectedStickerID
            && lhs.visibleVisualLayers == rhs.visibleVisualLayers
            && lhs.detachedTracks == rhs.detachedTracks
            && lhs.musicTracks == rhs.musicTracks
            && lhs.sfxTracks == rhs.sfxTracks
            && lhs.voiceoverSegments == rhs.voiceoverSegments
            && lhs.subtitleSegments == rhs.subtitleSegments
            && textOverlaysLayoutEqual(lhs.textOverlays, rhs.textOverlays)
            && lhs.stickerOverlays == rhs.stickerOverlays
            && lhs.clipLayouts == rhs.clipLayouts
            && lhs.totalDuration == rhs.totalDuration
            && lhs.draggingClipIndex == rhs.draggingClipIndex
            && lhs.clipDragTranslation == rhs.clipDragTranslation
            && lhs.rulerInterval == rhs.rulerInterval
            && lhs.rulerSubInterval == rhs.rulerSubInterval
            && lhs.isClipTrimming == rhs.isClipTrimming
    }

    private static func textOverlaysLayoutEqual(_ lhs: [TextOverlay], _ rhs: [TextOverlay]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (a, b) in zip(lhs, rhs) {
            if a.id != b.id
                || !CMTimeRangeEqual(a.timeRange, b.timeRange)
                || a.normalizedCenter != b.normalizedCenter
                || a.scale != b.scale
                || a.rotation != b.rotation
                || a.opacity != b.opacity
                || a.animation != b.animation {
                return false
            }
        }
        return true
    }

    static func rulerInterval(pixelsPerSecond: CGFloat) -> TimeInterval {
        if pixelsPerSecond > 90 { return 1 }
        if pixelsPerSecond > 45 { return 3 }
        return 5
    }

    static func rulerSubInterval(for rulerInterval: TimeInterval) -> TimeInterval {
        switch rulerInterval {
        case 5...: return 1
        case 3..<5: return 1
        default: return 0.5
        }
    }

    /// Time-accurate width — no minimum clamp that stretches past ruler duration.
    func clipWidth(_ clip: VideoClip) -> CGFloat {
        max(CGFloat(clip.scaledDuration.seconds) * pixelsPerSecond, 1)
    }

    /// Pixel width of the video track (transitions overlay clip edges, they do not add time).
    func videoTrackLayoutWidth() -> CGFloat {
        clips.reduce(CGFloat(0)) { partial, clip in
            partial + clipWidth(clip)
        }
    }

    func videoTrackVerticalRange() -> (minY: CGFloat, maxY: CGFloat) {
        var y = rulerHeight
        for layer in visibleVisualLayers {
            let height = layer == .video ? videoTrackContentHeight : trackRowHeight
            if layer == .video {
                return (y, y + height)
            }
            y += height + trackSpacing
        }
        return (rulerHeight, rulerHeight + videoTrackContentHeight)
    }

    func trackY(for layer: VisualLayer) -> CGFloat {
        var y = rulerHeight
        for item in visibleVisualLayers {
            let height = item == .video ? videoTrackContentHeight : trackRowHeight
            if item == layer { return y }
            y += height + trackSpacing
        }
        return y
    }

    func audioTrackStartY() -> CGFloat {
        var y = rulerHeight
        for layer in visibleVisualLayers {
            y += (layer == .video ? videoTrackContentHeight : trackRowHeight) + trackSpacing
        }
        if visibleAudioTrackCount > 0 {
            y += trackSpacing + 1
        }
        return y
    }

    var visibleAudioTrackCount: Int {
        var count = 0
        if !detachedTracks.isEmpty { count += 1 }
        if !musicTracks.isEmpty { count += 1 }
        if !sfxTracks.isEmpty { count += 1 }
        if !voiceoverSegments.isEmpty { count += 1 }
        return count
    }
}
