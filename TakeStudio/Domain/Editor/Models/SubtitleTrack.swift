import AVFoundation
import CoreGraphics
import Foundation
import UIKit

struct SubtitleStyle: Equatable, Sendable {
    var fontSize: CGFloat
    var colorHex: String
    var backgroundColorHex: String
    var position: CGPoint
    var hasShadow: Bool
    var hasBackground: Bool
    var fontWeight: UIFont.Weight
    var fontName: String?
    var opacity: CGFloat
    /// Stroke around glyphs (CapCut-style outline). `0` = off.
    var strokeWidth: CGFloat
    var strokeColorHex: String
    var shadowColorHex: String
    var shadowRadius: CGFloat
    /// Raw `NSTextAlignment` value (0 left / 1 center / 2 right) for Sendable storage.
    var alignmentRaw: Int

    var alignment: NSTextAlignment {
        get { NSTextAlignment(rawValue: alignmentRaw) ?? .center }
        set { alignmentRaw = newValue.rawValue }
    }

    init(
        fontSize: CGFloat = 24,
        colorHex: String = "#FFFFFF",
        backgroundColorHex: String = "#00000080",
        position: CGPoint = CGPoint(x: 0.5, y: 0.85),
        hasShadow: Bool = true,
        hasBackground: Bool = true,
        fontWeight: UIFont.Weight = .semibold,
        fontName: String? = nil,
        opacity: CGFloat = 1.0,
        strokeWidth: CGFloat = 0,
        strokeColorHex: String = "#000000",
        shadowColorHex: String = "#000000",
        shadowRadius: CGFloat = 4,
        alignment: NSTextAlignment = .center
    ) {
        self.fontSize = fontSize
        self.colorHex = colorHex
        self.backgroundColorHex = backgroundColorHex
        self.position = position
        self.hasShadow = hasShadow
        self.hasBackground = hasBackground
        self.fontWeight = fontWeight
        self.fontName = fontName
        self.opacity = opacity
        self.strokeWidth = strokeWidth
        self.strokeColorHex = strokeColorHex
        self.shadowColorHex = shadowColorHex
        self.shadowRadius = shadowRadius
        self.alignmentRaw = alignment.rawValue
    }

    static func preset(_ preset: SubtitleStylePreset) -> SubtitleStyle {
        switch preset {
        case .classic:
            return SubtitleStyle(fontSize: 24, colorHex: "#FFFFFF", backgroundColorHex: "#00000000", hasShadow: true, hasBackground: false)
        case .bold:
            return SubtitleStyle(fontSize: 32, colorHex: "#FFFFFF", backgroundColorHex: "#000000CC", hasShadow: false, hasBackground: true, fontWeight: .heavy)
        case .neon:
            return SubtitleStyle(fontSize: 28, colorHex: "#00FFCC", backgroundColorHex: "#00000000", hasShadow: true, hasBackground: false, fontWeight: .bold)
        case .minimal:
            return SubtitleStyle(fontSize: 18, colorHex: "#CCCCCC", backgroundColorHex: "#00000000", hasShadow: false, hasBackground: false, fontWeight: .regular)
        case .karaoke:
            return SubtitleStyle(fontSize: 26, colorHex: "#FFFF00", backgroundColorHex: "#00000080", hasShadow: true, hasBackground: true, fontWeight: .bold)
        }
    }
}

struct SubtitleTrack: Equatable, Sendable {
    var segments: [SubtitleSegment]
    var style: SubtitleStyle

    init(segments: [SubtitleSegment] = [], style: SubtitleStyle = .preset(.classic)) {
        self.segments = segments
        self.style = style
    }
}

struct SubtitleSegment: Identifiable, Equatable, Sendable {
    let id: UUID
    var text: String
    var timeRange: CMTimeRange
    var style: SubtitleStyle?
    var words: [SubtitleWord]?

    init(
        id: UUID = UUID(),
        text: String,
        timeRange: CMTimeRange,
        style: SubtitleStyle? = nil,
        words: [SubtitleWord]? = nil
    ) {
        self.id = id
        self.text = text
        self.timeRange = timeRange
        self.style = style
        self.words = words
    }

    static func == (lhs: SubtitleSegment, rhs: SubtitleSegment) -> Bool {
        lhs.id == rhs.id
            && lhs.text == rhs.text
            && CMTimeRangeEqual(lhs.timeRange, rhs.timeRange)
            && lhs.style == rhs.style
            && lhs.words == rhs.words
    }
}

struct SubtitleWord: Equatable, Sendable {
    var text: String
    var timeRange: CMTimeRange
}
