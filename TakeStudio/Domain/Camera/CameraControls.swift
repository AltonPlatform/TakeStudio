import AVFoundation
import CoreGraphics

enum CameraFlashMode: CaseIterable, Identifiable, Sendable {
    case off
    case on
    case auto

    var id: String {
        switch self {
        case .off: return "off"
        case .on: return "on"
        case .auto: return "auto"
        }
    }

    var iconName: String {
        switch self {
        case .off: return "bolt.slash.fill"
        case .on: return "bolt.fill"
        case .auto: return "bolt.badge.automatic.fill"
        }
    }

    var avFlashMode: AVCaptureDevice.FlashMode {
        switch self {
        case .off: return .off
        case .on: return .on
        case .auto: return .auto
        }
    }

    func next() -> CameraFlashMode {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self) else { return .off }
        return all[(index + 1) % all.count]
    }
}

struct FocusIndicatorState: Equatable, Sendable {
    var point: CGPoint
    var isLocked: Bool
    var exposureBias: Float = 0
    var exposureDragTranslation: CGFloat = 0
    var isAdjustingExposure: Bool = false
}
