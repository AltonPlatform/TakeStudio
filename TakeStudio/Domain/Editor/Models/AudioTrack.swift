import AVFoundation
import Foundation

struct AudioTrack: Identifiable, Equatable, Sendable {
    let id: UUID
    var sourceURL: URL
    var timeRange: CMTimeRange
    var startTime: CMTime
    var volume: Float
    var isFadeIn: Bool
    var isFadeOut: Bool
    var isDetachedFromVideo: Bool
    var kind: AudioTrackKind
    var title: String
    var isLooping: Bool

    init(
        id: UUID = UUID(),
        sourceURL: URL,
        timeRange: CMTimeRange,
        startTime: CMTime = .zero,
        volume: Float = 1.0,
        isFadeIn: Bool = false,
        isFadeOut: Bool = false,
        isDetachedFromVideo: Bool = false,
        kind: AudioTrackKind = .music,
        title: String = "Audio",
        isLooping: Bool = false
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.timeRange = timeRange
        self.startTime = startTime
        self.volume = volume
        self.isFadeIn = isFadeIn
        self.isFadeOut = isFadeOut
        self.isDetachedFromVideo = isDetachedFromVideo
        self.kind = kind
        self.title = title
        self.isLooping = isLooping
    }

    var asset: AVURLAsset { EditorAVAssetCache.shared.asset(for: sourceURL) }

    static func == (lhs: AudioTrack, rhs: AudioTrack) -> Bool {
        lhs.id == rhs.id
            && lhs.sourceURL == rhs.sourceURL
            && CMTimeRangeEqual(lhs.timeRange, rhs.timeRange)
            && CMTimeCompare(lhs.startTime, rhs.startTime) == 0
            && lhs.volume == rhs.volume
            && lhs.isFadeIn == rhs.isFadeIn
            && lhs.isFadeOut == rhs.isFadeOut
            && lhs.isDetachedFromVideo == rhs.isDetachedFromVideo
            && lhs.kind == rhs.kind
            && lhs.title == rhs.title
            && lhs.isLooping == rhs.isLooping
    }
}

struct VoiceoverTrack: Equatable, Sendable {
    var segments: [VoiceoverSegment]

    init(segments: [VoiceoverSegment] = []) {
        self.segments = segments
    }
}

struct VoiceoverSegment: Identifiable, Equatable, Sendable {
    let id: UUID
    var fileURL: URL
    var startTime: CMTime
    var duration: CMTime
    var volume: Float

    init(
        id: UUID = UUID(),
        fileURL: URL,
        startTime: CMTime,
        duration: CMTime,
        volume: Float = 1.0
    ) {
        self.id = id
        self.fileURL = fileURL
        self.startTime = startTime
        self.duration = duration
        self.volume = volume
    }

    static func == (lhs: VoiceoverSegment, rhs: VoiceoverSegment) -> Bool {
        lhs.id == rhs.id
            && lhs.fileURL == rhs.fileURL
            && CMTimeCompare(lhs.startTime, rhs.startTime) == 0
            && CMTimeCompare(lhs.duration, rhs.duration) == 0
            && lhs.volume == rhs.volume
    }
}
