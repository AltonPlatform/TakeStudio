import AVFoundation
import Foundation

struct EditorProjectSnapshot: Sendable {
    var clips: [VideoClip]
    var audioTracks: [AudioTrack]
    var voiceoverTrack: VoiceoverTrack?
    var subtitleTrack: SubtitleTrack?
    var textOverlays: [TextOverlay]
    var stickerOverlays: [StickerOverlay]
    var globalFilterIDs: [String]
    var globalColorAdjustments: ColorAdjustments
    var aspectRatio: AspectRatio
    var layerOrder: [VisualLayer]

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
        for sticker in stickerOverlays {
            if let url = sticker.imageURL {
                urls.insert(url)
            }
        }
        return urls
    }
}

extension EditorProject {
    func snapshot() -> EditorProjectSnapshot {
        EditorProjectSnapshot(
            clips: clips,
            audioTracks: audioTracks,
            voiceoverTrack: voiceoverTrack,
            subtitleTrack: subtitleTrack,
            textOverlays: textOverlays,
            stickerOverlays: stickerOverlays,
            globalFilterIDs: globalFilterIDs,
            globalColorAdjustments: globalColorAdjustments,
            aspectRatio: aspectRatio,
            layerOrder: layerOrder
        )
    }

    func restore(from snapshot: EditorProjectSnapshot) {
        clips = snapshot.clips
        audioTracks = snapshot.audioTracks
        voiceoverTrack = snapshot.voiceoverTrack
        subtitleTrack = snapshot.subtitleTrack
        textOverlays = snapshot.textOverlays
        stickerOverlays = snapshot.stickerOverlays
        globalFilterIDs = snapshot.globalFilterIDs
        globalColorAdjustments = snapshot.globalColorAdjustments
        aspectRatio = snapshot.aspectRatio
        layerOrder = snapshot.layerOrder
        normalizeLayerOrder()
        updateCompositionStartTimes()
    }
}
