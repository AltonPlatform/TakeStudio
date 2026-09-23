import AVFoundation
import CoreGraphics
import Foundation

struct TextOverlay: Identifiable, Equatable, Sendable {
    let id: UUID
    var text: String
    var timeRange: CMTimeRange
    var style: SubtitleStyle
    var animation: TextAnimation
    var normalizedCenter: CGPoint
    var scale: CGFloat
    var rotation: CGFloat
    var opacity: CGFloat

    init(
        id: UUID = UUID(),
        text: String = "Text",
        timeRange: CMTimeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 3, preferredTimescale: 600)),
        style: SubtitleStyle = SubtitleStyle(fontSize: 28, colorHex: "#FFFFFF"),
        animation: TextAnimation = .none,
        normalizedCenter: CGPoint = CGPoint(x: 0.5, y: 0.5),
        scale: CGFloat = 1.0,
        rotation: CGFloat = 0,
        opacity: CGFloat = 1.0
    ) {
        self.id = id
        self.text = text
        self.timeRange = timeRange
        self.style = style
        self.animation = animation
        self.normalizedCenter = normalizedCenter
        self.scale = scale
        self.rotation = rotation
        self.opacity = opacity
    }

    static func == (lhs: TextOverlay, rhs: TextOverlay) -> Bool {
        lhs.id == rhs.id
            && lhs.text == rhs.text
            && CMTimeRangeEqual(lhs.timeRange, rhs.timeRange)
            && lhs.style == rhs.style
            && lhs.animation == rhs.animation
            && lhs.normalizedCenter == rhs.normalizedCenter
            && lhs.scale == rhs.scale
            && lhs.rotation == rhs.rotation
            && lhs.opacity == rhs.opacity
    }
}

struct StickerOverlay: Identifiable, Equatable, Sendable {
    let id: UUID
    var emoji: String?
    var imageURL: URL?
    var timeRange: CMTimeRange
    var normalizedCenter: CGPoint
    var scale: CGFloat
    var rotation: CGFloat
    var opacity: CGFloat

    init(
        id: UUID = UUID(),
        emoji: String? = "😀",
        imageURL: URL? = nil,
        timeRange: CMTimeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 3, preferredTimescale: 600)),
        normalizedCenter: CGPoint = CGPoint(x: 0.5, y: 0.5),
        scale: CGFloat = 1.0,
        rotation: CGFloat = 0,
        opacity: CGFloat = 1.0
    ) {
        self.id = id
        self.emoji = emoji
        self.imageURL = imageURL
        self.timeRange = timeRange
        self.normalizedCenter = normalizedCenter
        self.scale = scale
        self.rotation = rotation
        self.opacity = opacity
    }

    static func == (lhs: StickerOverlay, rhs: StickerOverlay) -> Bool {
        lhs.id == rhs.id
            && lhs.emoji == rhs.emoji
            && lhs.imageURL == rhs.imageURL
            && CMTimeRangeEqual(lhs.timeRange, rhs.timeRange)
            && lhs.normalizedCenter == rhs.normalizedCenter
            && lhs.scale == rhs.scale
            && lhs.rotation == rhs.rotation
            && lhs.opacity == rhs.opacity
    }
}
