import AVFoundation

enum FlashMode: CaseIterable, Identifiable, Sendable {
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

    func next() -> FlashMode {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self) else { return .off }
        return all[(index + 1) % all.count]
    }
}

struct FlashController {
    var mode: FlashMode = .auto

    mutating func cycle() {
        mode = mode.next()
    }

    func torchEnabled(for captureMode: CaptureMode) -> Bool {
        captureMode.isVideo && mode == .on
    }
}
