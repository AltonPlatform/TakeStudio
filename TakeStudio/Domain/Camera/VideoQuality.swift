import AVFoundation
import CoreGraphics

enum VideoQuality: String, CaseIterable, Identifiable, Sendable {
    case hd720p30
    case hd1080p30
    case hd1080p60

    var id: String { rawValue }

    var sessionPreset: AVCaptureSession.Preset {
        switch self {
        case .hd720p30:
            return .hd1280x720
        case .hd1080p30, .hd1080p60:
            return .hd1920x1080
        }
    }

    var outputWidth: Int {
        switch self {
        case .hd720p30:
            return 720
        case .hd1080p30, .hd1080p60:
            return 1080
        }
    }

    var outputHeight: Int {
        switch self {
        case .hd720p30:
            return 1280
        case .hd1080p30, .hd1080p60:
            return 1920
        }
    }

    var outputSize: CGSize {
        CGSize(width: outputWidth, height: outputHeight)
    }

    /// Target average bitrate for HEVC capture (more efficient than H.264 at lower rates).
    var bitrate: Int {
        switch self {
        case .hd720p30:
            return 3_000_000
        case .hd1080p30:
            return 6_000_000
        case .hd1080p60:
            return 10_000_000
        }
    }

    var frameRate: Int32 {
        switch self {
        case .hd720p30, .hd1080p30:
            return 30
        case .hd1080p60:
            return 60
        }
    }

    var displayName: String {
        switch self {
        case .hd720p30:
            return "720p · 30 fps"
        case .hd1080p30:
            return "1080p · 30 fps"
        case .hd1080p60:
            return "1080p · 60 fps"
        }
    }

    var shortName: String {
        switch self {
        case .hd720p30:
            return "720p"
        case .hd1080p30, .hd1080p60:
            return "1080p"
        }
    }
}
