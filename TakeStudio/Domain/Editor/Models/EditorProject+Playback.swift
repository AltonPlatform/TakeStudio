import AVFoundation
import Foundation

/// Fields that affect AVFoundation preview/export pipeline (not SwiftUI overlay canvas).
struct EditorPlaybackPipelineState: Equatable, Sendable {
    var clips: [VideoClip]
    var audioTracks: [AudioTrack]
    var voiceoverTrack: VoiceoverTrack?
    var subtitleTrack: SubtitleTrack?
    var globalFilterIDs: [String]
    var globalColorAdjustments: ColorAdjustments
    var aspectRatio: AspectRatio
}

extension EditorProject {
    var playbackPipelineState: EditorPlaybackPipelineState {
        EditorPlaybackPipelineState(
            clips: clips,
            audioTracks: audioTracks,
            voiceoverTrack: voiceoverTrack,
            subtitleTrack: subtitleTrack,
            globalFilterIDs: globalFilterIDs,
            globalColorAdjustments: globalColorAdjustments,
            aspectRatio: aspectRatio
        )
    }

    func requiresCustomCompositorForPreview(bakeOverlays: Bool = false) -> Bool {
        Self.requiresCustomCompositor(for: self, bakeOverlays: bakeOverlays)
    }

    /// Raw asset playback without building a composition — only when trim/speed/effects/audio are absent.
    func canUseDirectPreviewPlayback() -> Bool {
        guard clips.count == 1, let clip = clips.first else { return false }
        guard !requiresCustomCompositorForPreview() else { return false }
        guard clip.speed == 1.0 else { return false }
        guard clip.timeRange.start.seconds < 0.05 else { return false }
        // Tail trim: require no recoverable tail (source end matches clip end).
        guard !clip.hasRecoverableTail else { return false }
        guard abs(clip.volume - 1) < 0.01, !clip.isMuted else { return false }
        guard audioTracks.isEmpty else { return false }
        if let voiceoverTrack, !voiceoverTrack.segments.isEmpty { return false }
        return true
    }

    /// Raw file copy when the timeline is a single unedited clip that already fits export quality.
    /// Avoids a second HEVC encode after camera capture (server prefers bitstream copy).
    func canUseLosslessExport(quality: ExportQuality) async -> Bool {
        guard canUseDirectPreviewPlayback(), let clip = clips.first else { return false }
        guard audioTracks.isEmpty else { return false }
        if let voiceoverTrack, !voiceoverTrack.segments.isEmpty { return false }
        // Must use the full source range (no trim).
        guard !clip.hasRecoverableHead, !clip.hasRecoverableTail else { return false }
        guard abs(clip.volume - 1) < 0.01, !clip.isMuted else { return false }
        // Composition applies aspect letterboxing — only copy when default portrait.
        guard aspectRatio == .portrait9x16 else { return false }

        do {
            let tracks = try await clip.asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else { return false }
            let naturalSize = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let size = naturalSize.applying(transform)
            let width = abs(size.width)
            let height = abs(size.height)
            guard width >= 2, height >= 2 else { return false }
            return max(width, height) <= quality.maxLongEdge + 1
        } catch {
            return false
        }
    }

    static func requiresCustomCompositor(for project: EditorProject, bakeOverlays: Bool) -> Bool {
        if bakeOverlays {
            if !project.textOverlays.isEmpty || !project.stickerOverlays.isEmpty { return true }
            if !(project.subtitleTrack?.segments.isEmpty ?? true) { return true }
        }
        if !project.globalFilterIDs.isEmpty { return true }
        if !project.globalColorAdjustments.isIdentity { return true }
        if project.clips.contains(where: {
            !$0.filterIDs.isEmpty
                || !$0.colorAdjustments.isIdentity
                || !$0.framing.isIdentity
                || $0.greenScreenEffect != nil
        }) { return true }
        // `.fade` / `.cut` use standard opacity ramps in passthrough composition.
        // Only geometric transitions need the custom compositor.
        if project.clips.contains(where: {
            let transition = $0.transition ?? .cut
            return transition != .cut && transition != .fade
        }) { return true }
        return false
    }
}

extension EditorProjectSnapshot {
    var playbackPipelineState: EditorPlaybackPipelineState {
        EditorPlaybackPipelineState(
            clips: clips,
            audioTracks: audioTracks,
            voiceoverTrack: voiceoverTrack,
            subtitleTrack: subtitleTrack,
            globalFilterIDs: globalFilterIDs,
            globalColorAdjustments: globalColorAdjustments,
            aspectRatio: aspectRatio
        )
    }
}
