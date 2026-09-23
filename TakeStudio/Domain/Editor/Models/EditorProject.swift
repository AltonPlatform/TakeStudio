import AVFoundation
import Foundation
import Observation

@Observable
final class EditorProject {
    var clips: [VideoClip]
    var audioTracks: [AudioTrack]
    var voiceoverTrack: VoiceoverTrack?
    var subtitleTrack: SubtitleTrack?
    var textOverlays: [TextOverlay]
    var stickerOverlays: [StickerOverlay]
    var globalFilterIDs: [String]
    var globalColorAdjustments: ColorAdjustments
    var aspectRatio: AspectRatio
    /// Top-to-bottom timeline order; top entry is the topmost visual layer on the frame.
    var layerOrder: [VisualLayer]

    init(
        clips: [VideoClip] = [],
        audioTracks: [AudioTrack] = [],
        voiceoverTrack: VoiceoverTrack? = nil,
        subtitleTrack: SubtitleTrack? = nil,
        textOverlays: [TextOverlay] = [],
        stickerOverlays: [StickerOverlay] = [],
        globalFilterIDs: [String] = [],
        globalColorAdjustments: ColorAdjustments = .identity,
        aspectRatio: AspectRatio = .portrait9x16,
        layerOrder: [VisualLayer] = VisualLayer.defaultOrder
    ) {
        self.clips = clips
        self.audioTracks = audioTracks
        self.voiceoverTrack = voiceoverTrack
        self.subtitleTrack = subtitleTrack
        self.textOverlays = textOverlays
        self.stickerOverlays = stickerOverlays
        self.globalFilterIDs = globalFilterIDs
        self.globalColorAdjustments = globalColorAdjustments
        self.aspectRatio = aspectRatio
        self.layerOrder = layerOrder
    }

    /// Isolated copy for background composition builds — never mutate the live project off-main.
    convenience init(snapshot: EditorProjectSnapshot) {
        self.init(
            clips: snapshot.clips,
            audioTracks: snapshot.audioTracks,
            voiceoverTrack: snapshot.voiceoverTrack,
            subtitleTrack: snapshot.subtitleTrack,
            textOverlays: snapshot.textOverlays,
            stickerOverlays: snapshot.stickerOverlays,
            globalFilterIDs: snapshot.globalFilterIDs,
            globalColorAdjustments: snapshot.globalColorAdjustments,
            aspectRatio: snapshot.aspectRatio,
            layerOrder: snapshot.layerOrder
        )
        normalizeLayerOrder()
        updateCompositionStartTimes()
    }

    /// Ensures `.video` remains the bottommost visual layer.
    func normalizeLayerOrder() {
        var order = layerOrder.filter { VisualLayer.allCases.contains($0) }
        for layer in VisualLayer.allCases where !order.contains(layer) {
            order.append(layer)
        }
        if let videoIndex = order.firstIndex(of: .video), videoIndex != order.count - 1 {
            order.remove(at: videoIndex)
            order.append(.video)
        }
        layerOrder = order
    }

    var totalDuration: CMTime {
        timelineDuration
    }

    /// Composition timeline duration accounting for transition overlaps.
    var timelineDuration: CMTime {
        guard !clips.isEmpty else { return .zero }
        var end = CMTime.zero
        for (index, clip) in clips.enumerated() {
            var insertAt = end
            if index > 0 {
                let previous = clips[index - 1]
                if let transition = previous.transition, transition != .cut {
                    let half = CMTime(seconds: previous.transitionDuration / 2, preferredTimescale: 600)
                    insertAt = CMTimeSubtract(end, half)
                }
            }
            let clipEnd = CMTimeAdd(insertAt, clip.scaledDuration)
            if let transition = clip.transition, transition != .cut, index < clips.count - 1 {
                end = CMTimeSubtract(
                    clipEnd,
                    CMTime(seconds: clip.transitionDuration / 2, preferredTimescale: 600)
                )
            } else {
                end = clipEnd
            }
        }
        return end
    }

    var totalDurationSeconds: TimeInterval {
        timelineDuration.seconds
    }

    func updateCompositionStartTimes() {
        // Must match EditorCompositionBuilder insert math: each transition subtracts
        // half at the outgoing end AND half at the incoming insert → full overlap of
        // transitionDuration. A single half-subtraction here used to drift Split/playhead.
        var end = CMTime.zero
        for index in clips.indices {
            var insertAt = end
            if index > 0 {
                let previous = clips[index - 1]
                if let transition = previous.transition, transition != .cut {
                    let half = CMTime(seconds: previous.transitionDuration / 2, preferredTimescale: 600)
                    insertAt = CMTimeSubtract(end, half)
                }
            }
            clips[index].compositionStartTime = insertAt
            let clipEnd = CMTimeAdd(insertAt, clips[index].scaledDuration)
            if let transition = clips[index].transition, transition != .cut, index < clips.count - 1 {
                end = CMTimeSubtract(
                    clipEnd,
                    CMTime(seconds: clips[index].transitionDuration / 2, preferredTimescale: 600)
                )
            } else {
                end = clipEnd
            }
        }
    }

    func clip(at compositionTime: CMTime) -> VideoClip? {
        clips.last { clip in
            let end = CMTimeAdd(clip.compositionStartTime, clip.scaledDuration)
            return compositionTime >= clip.compositionStartTime && compositionTime < end
        }
    }

    func compositionTime(forClip clipID: UUID, localTime: CMTime) -> CMTime {
        guard let clip = clips.first(where: { $0.id == clipID }) else { return localTime }
        return CMTimeAdd(clip.compositionStartTime, localTime)
    }

    static func fromInitialVideo(url: URL) async throws -> EditorProject {
        let asset = EditorAVAssetCache.shared.asset(for: url)
        let isPlayable = try await asset.load(.isPlayable)
        guard isPlayable else {
            throw EditorCompositionError.buildFailed
        }
        let duration = try await asset.load(.duration)
        let clip = VideoClip.make(from: url, duration: duration)
        let project = EditorProject(clips: [clip])
        project.updateCompositionStartTimes()
        return project
    }

    func referencedMediaURLs() -> Set<URL> {
        var urls = Set<URL>()
        for clip in clips {
            urls.insert(clip.sourceURL)
            if let effect = clip.greenScreenEffect {
                switch effect.backgroundSource {
                case .image(let url), .videoURL(let url):
                    urls.insert(url)
                case .color:
                    break
                }
            }
        }
        for track in audioTracks {
            urls.insert(track.sourceURL)
        }
        if let segments = voiceoverTrack?.segments {
            for segment in segments {
                urls.insert(segment.fileURL)
            }
        }
        return urls
    }

    static func fromClipURLs(_ urls: [URL]) async throws -> EditorProject {
        var clips: [VideoClip] = []
        for url in urls {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            clips.append(VideoClip.make(from: url, duration: duration))
        }
        let project = EditorProject(clips: clips)
        project.updateCompositionStartTimes()
        return project
    }
}
