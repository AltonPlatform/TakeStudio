import Foundation

enum CaptureMode: String, CaseIterable, Identifiable, Sendable {
    case video15
    case video1min
    case video3min
    case video10min

    var id: String { rawValue }

    var title: String {
        switch self {
        case .video15: return "15 sec"
        case .video1min: return "1 min"
        case .video3min: return "3 min"
        case .video10min: return "10 min"
        }
    }

    var shortTitle: String {
        switch self {
        case .video15: return "15s"
        case .video1min: return "1m"
        case .video3min: return "3m"
        case .video10min: return "10m"
        }
    }

    var isVideo: Bool { true }

    var requiresPremium: Bool { self == .video10min }

    var durationLimit: TimeInterval? {
        switch self {
        case .video15: return 15
        case .video1min: return 60
        case .video3min: return 180
        case .video10min: return 600
        }
    }

    static var videoModes: [CaptureMode] {
        allCases
    }
}
