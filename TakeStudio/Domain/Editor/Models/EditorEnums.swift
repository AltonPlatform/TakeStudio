import Foundation
import SwiftUI
import UIKit

enum AspectRatio: String, CaseIterable, Identifiable, Sendable {
    case portrait9x16 = "9:16"
    case square1x1 = "1:1"
    case landscape16x9 = "16:9"

    var id: String { rawValue }

    var width: CGFloat {
        switch self {
        case .portrait9x16: return 9
        case .square1x1: return 1
        case .landscape16x9: return 16
        }
    }

    var height: CGFloat {
        switch self {
        case .portrait9x16: return 16
        case .square1x1: return 1
        case .landscape16x9: return 9
        }
    }
}

enum ClipTransition: String, CaseIterable, Identifiable, Sendable {
    case cut
    case fade
    case slideLeft
    case slideRight
    case slideUp
    case slideDown
    case zoomIn
    case zoomOut

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cut: return "Cut"
        case .fade: return "Fade"
        case .slideLeft: return "Slide Left"
        case .slideRight: return "Slide Right"
        case .slideUp: return "Slide Up"
        case .slideDown: return "Slide Down"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        }
    }

    var duration: TimeInterval {
        self == .cut ? 0 : 0.5
    }
}

enum TextAnimation: String, CaseIterable, Identifiable, Sendable {
    case none
    case fade
    case typewriter
    case slide
    case slideUp
    case slideDown
    case pop
    case drift
    case bounce
    case scaleUp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .fade: return "Fade"
        case .typewriter: return "Typewriter"
        case .slide: return "Slide"
        case .slideUp: return "Slide Up"
        case .slideDown: return "Slide Down"
        case .pop: return "Pop"
        case .drift: return "Drift"
        case .bounce: return "Bounce"
        case .scaleUp: return "Scale Up"
        }
    }
}

enum TextComposerMode: String, Sendable {
    case editing
    case manipulating
    case stylePanel
}

enum EditorTool: String, CaseIterable, Identifiable, Sendable {
    case edit
    case audio
    case text
    case subtitles
    case effects
    case transform

    var id: String { rawValue }

    var title: String {
        switch self {
        case .edit: return "Edit"
        case .audio: return "Audio"
        case .text: return "Text"
        case .subtitles: return "Subtitles"
        case .effects: return "Effects"
        case .transform: return "Transform"
        }
    }

    var iconName: String {
        switch self {
        case .edit: return "scissors"
        case .audio: return "waveform"
        case .text: return "textformat"
        case .subtitles: return "captions.bubble"
        case .effects: return "wand.and.stars"
        case .transform: return "crop.rotate"
        }
    }
}

enum ExportQuality: String, CaseIterable, Identifiable, Sendable {
    case p480
    case p720
    case p1080
    case p4K

    var id: String { rawValue }

    var title: String {
        switch self {
        case .p480: return "480p"
        case .p720: return "720p"
        case .p1080: return "1080p"
        case .p4K: return "4K"
        }
    }

    var maxLongEdge: CGFloat {
        switch self {
        case .p480: return 854
        case .p720: return 1280
        case .p1080: return 1920
        case .p4K: return 3840
        }
    }
}

enum SubtitleStylePreset: String, CaseIterable, Identifiable, Sendable {
    case classic
    case bold
    case neon
    case minimal
    case karaoke

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: return "Classic"
        case .bold: return "Bold"
        case .neon: return "Neon"
        case .minimal: return "Minimal"
        case .karaoke: return "Karaoke"
        }
    }
}

enum AudioTrackKind: String, Sendable {
    case detached
    case music
    case sfx
}

/// Visual layers composited on the video frame. Top of `layerOrder` = topmost on screen.
enum VisualLayer: String, CaseIterable, Identifiable, Sendable {
    case textOverlays
    case stickers
    case subtitles
    case video

    var id: String { rawValue }

    static let defaultOrder: [VisualLayer] = [.textOverlays, .stickers, .subtitles, .video]

    var icon: String {
        switch self {
        case .textOverlays: return "✏️"
        case .stickers: return "😀"
        case .subtitles: return "💬"
        case .video: return "🎬"
        }
    }

    var systemImage: String {
        switch self {
        case .textOverlays: return "textformat"
        case .stickers: return "face.smiling"
        case .subtitles: return "captions.bubble"
        case .video: return "film"
        }
    }

    var title: String {
        switch self {
        case .textOverlays: return "Text"
        case .stickers: return "Stickers"
        case .subtitles: return "Subs"
        case .video: return "Video"
        }
    }
}

enum EditorTimelineTrack: String, CaseIterable, Identifiable, Sendable {
    case video
    case detachedAudio
    case music
    case sfx
    case voiceover
    case subtitles
    case textOverlays

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .video: return "🎬"
        case .detachedAudio: return "🔊"
        case .music: return "🎵"
        case .sfx: return "💥"
        case .voiceover: return "🎙"
        case .subtitles: return "💬"
        case .textOverlays: return "✏️"
        }
    }

    var systemImage: String {
        switch self {
        case .video: return "film"
        case .detachedAudio: return "speaker.wave.2"
        case .music: return "music.note"
        case .sfx: return "sparkles"
        case .voiceover: return "mic.fill"
        case .subtitles: return "captions.bubble"
        case .textOverlays: return "textformat"
        }
    }

    var title: String {
        switch self {
        case .video: return "Video"
        case .detachedAudio: return "Audio"
        case .music: return "Music"
        case .sfx: return "SFX"
        case .voiceover: return "Voice"
        case .subtitles: return "Subs"
        case .textOverlays: return "Text"
        }
    }
}

enum EditorColorHex {
    /// Converts a SwiftUI `Color` to `#RRGGBB`, surviving Display P3 by converting via sRGB when needed.
    static func hexString(from color: Color) -> String {
        hexString(from: UIColor(color))
    }

    static func hexString(from uiColor: UIColor) -> String {
        if let components = uiColor.cgColor.converted(
            to: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            intent: .defaultIntent,
            options: nil
        )?.components, components.count >= 3 {
            let r = Int((components[0] * 255).rounded())
            let g = Int((components[1] * 255).rounded())
            let b = Int((components[2] * 255).rounded())
            return String(
                format: "#%02X%02X%02X",
                max(0, min(255, r)),
                max(0, min(255, g)),
                max(0, min(255, b))
            )
        }

        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if uiColor.getRed(&r, green: &g, blue: &b, alpha: &a) {
            return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
        }

        var white: CGFloat = 0
        if uiColor.getWhite(&white, alpha: &a) {
            let v = Int(white * 255)
            return String(format: "#%02X%02X%02X", v, v, v)
        }

        return "#FFFFFF"
    }
}
