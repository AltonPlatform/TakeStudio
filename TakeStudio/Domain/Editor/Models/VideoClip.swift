import AVFoundation
import CoreGraphics
import Foundation

struct VideoClip: Identifiable, Equatable, Sendable {
    static let minTimelineDuration: TimeInterval = 0.2

    let id: UUID
    var sourceURL: URL
    /// Active in/out within the source file (timeline-visible range).
    var timeRange: CMTimeRange
    /// Full recoverable media range — trim handles cannot go outside this span.
    var sourceTimeRange: CMTimeRange
    var speed: Double
    var volume: Float
    var isMuted: Bool
    var filterIDs: [String]
    var colorAdjustments: ColorAdjustments
    var framing: ClipFraming
    var transform: CGAffineTransform
    var hasDetachedAudio: Bool
    var transition: ClipTransition?
    var transitionDuration: Double
    var greenScreenEffect: GreenScreenEffect?
    /// Composition timeline position — computed when building, stored for UI sync.
    var compositionStartTime: CMTime

    init(
        id: UUID = UUID(),
        sourceURL: URL,
        timeRange: CMTimeRange,
        sourceTimeRange: CMTimeRange? = nil,
        speed: Double = 1.0,
        volume: Float = 1.0,
        isMuted: Bool = false,
        filterIDs: [String] = [],
        colorAdjustments: ColorAdjustments = .identity,
        framing: ClipFraming = .identity,
        transform: CGAffineTransform = .identity,
        hasDetachedAudio: Bool = false,
        transition: ClipTransition? = nil,
        transitionDuration: Double = 0.3,
        greenScreenEffect: GreenScreenEffect? = nil,
        compositionStartTime: CMTime = .zero
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.timeRange = timeRange
        self.sourceTimeRange = sourceTimeRange ?? timeRange
        self.speed = speed
        self.volume = volume
        self.isMuted = isMuted
        self.filterIDs = filterIDs
        self.colorAdjustments = colorAdjustments
        self.framing = framing
        self.transform = transform
        self.hasDetachedAudio = hasDetachedAudio
        self.transition = transition
        self.transitionDuration = transitionDuration
        self.greenScreenEffect = greenScreenEffect
        self.compositionStartTime = compositionStartTime
    }

    var asset: AVURLAsset { EditorAVAssetCache.shared.asset(for: sourceURL) }

    var scaledDuration: CMTime {
        // Preserve source timescale at 1× so model layout matches AVComposition inserts
        // (re-quantizing to 600 created Split/playhead drift and instruction gaps).
        if abs(speed - 1.0) < 0.001 {
            return timeRange.duration
        }
        return CMTime(
            seconds: timeRange.duration.seconds / max(speed, 0.01),
            preferredTimescale: 600
        )
    }

    var hasRecoverableHead: Bool {
        CMTimeCompare(timeRange.start, sourceTimeRange.start) > 0
    }

    var hasRecoverableTail: Bool {
        CMTimeCompare(timeRange.endTime, sourceTimeRange.endTime) < 0
    }

    func endTrimmed(
        timelineDelta: CGFloat,
        pixelsPerSecond: CGFloat,
        anchor: CMTimeRange
    ) -> CMTimeRange? {
        let deltaSource = TimeInterval(timelineDelta / pixelsPerSecond) * speed
        let newEnd = CMTimeAdd(anchor.endTime, CMTime(seconds: deltaSource, preferredTimescale: 600))
        return clampedTimeRange(start: anchor.start, end: newEnd)
    }

    func startTrimmed(
        timelineDelta: CGFloat,
        pixelsPerSecond: CGFloat,
        anchor: CMTimeRange
    ) -> CMTimeRange? {
        let deltaSource = TimeInterval(timelineDelta / pixelsPerSecond) * speed
        let newStart = CMTimeAdd(anchor.start, CMTime(seconds: deltaSource, preferredTimescale: 600))
        return clampedTimeRange(start: newStart, end: anchor.endTime)
    }

    func clampedTimeRange(start: CMTime, end: CMTime) -> CMTimeRange? {
        let minSource = CMTime(
            seconds: Self.minTimelineDuration * speed,
            preferredTimescale: 600
        )
        var clampedStart = CMTimeMaximum(sourceTimeRange.start, start)
        var clampedEnd = CMTimeMinimum(sourceTimeRange.endTime, end)

        if CMTimeCompare(clampedEnd, CMTimeAdd(clampedStart, minSource)) < 0 {
            clampedEnd = CMTimeAdd(clampedStart, minSource)
        }
        if CMTimeCompare(clampedEnd, CMTimeAdd(clampedStart, minSource)) < 0 {
            clampedStart = CMTimeSubtract(clampedEnd, minSource)
            clampedStart = CMTimeMaximum(sourceTimeRange.start, clampedStart)
        }
        guard CMTimeCompare(clampedEnd, CMTimeAdd(clampedStart, minSource)) >= 0 else {
            return nil
        }
        return CMTimeRange.from(start: clampedStart, end: clampedEnd)
    }

    static func == (lhs: VideoClip, rhs: VideoClip) -> Bool {
        lhs.id == rhs.id
            && lhs.sourceURL == rhs.sourceURL
            && CMTimeRangeEqual(lhs.timeRange, rhs.timeRange)
            && CMTimeRangeEqual(lhs.sourceTimeRange, rhs.sourceTimeRange)
            && lhs.speed == rhs.speed
            && lhs.volume == rhs.volume
            && lhs.isMuted == rhs.isMuted
            && lhs.filterIDs == rhs.filterIDs
            && lhs.colorAdjustments == rhs.colorAdjustments
            && lhs.framing == rhs.framing
            && lhs.transform == rhs.transform
            && lhs.hasDetachedAudio == rhs.hasDetachedAudio
            && lhs.transition == rhs.transition
            && lhs.transitionDuration == rhs.transitionDuration
            && lhs.greenScreenEffect == rhs.greenScreenEffect
            && CMTimeCompare(lhs.compositionStartTime, rhs.compositionStartTime) == 0
    }
}

extension VideoClip {
    static func make(from url: URL, duration: CMTime) -> VideoClip {
        let range = CMTimeRange(start: .zero, duration: duration)
        return VideoClip(
            sourceURL: url,
            timeRange: range,
            sourceTimeRange: range
        )
    }
}
