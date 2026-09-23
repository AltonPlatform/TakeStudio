import AVFoundation
import UIKit

enum CaptureVideoOrientation {
    case portrait
    case portraitUpsideDown
    case landscapeRight
    case landscapeLeft

    var isPortrait: Bool {
        self == .portrait || self == .portraitUpsideDown
    }
}

enum CaptureOrientationManager {
    private(set) static var cachedRotationAngle: CGFloat = 90

    @MainActor
    static func refreshCachedOrientation() {
        cachedRotationAngle = rotationAngle(for: currentVideoOrientation())
    }

    static func videoOrientation(for interfaceOrientation: UIInterfaceOrientation) -> CaptureVideoOrientation {
        switch interfaceOrientation {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default: return .portrait
        }
    }

    static func cachedVideoOrientation() -> CaptureVideoOrientation {
        switch cachedRotationAngle {
        case 90: return .portrait
        case 270: return .portraitUpsideDown
        case 180: return .landscapeRight
        default: return .landscapeLeft
        }
    }

    @MainActor
    static func currentVideoOrientation() -> CaptureVideoOrientation {
        videoOrientation(for: interfaceOrientation())
    }

    static func applyPreviewSettings(to connection: AVCaptureConnection?, mirrored: Bool) {
        applyPreviewSettings(to: connection, mirrored: mirrored, rotationAngle: cachedRotationAngle)
    }

    static func applyPreviewSettings(
        to connection: AVCaptureConnection?,
        mirrored: Bool,
        rotationAngle: CGFloat
    ) {
        guard let connection else { return }
        if connection.isVideoRotationAngleSupported(rotationAngle) {
            connection.videoRotationAngle = rotationAngle
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
    }

    static func applyCaptureRotation(to connection: AVCaptureConnection?, mirrored: Bool) {
        applyPreviewSettings(to: connection, mirrored: mirrored, rotationAngle: cachedRotationAngle)
    }

    static func rotationAngle(for orientation: CaptureVideoOrientation) -> CGFloat {
        switch orientation {
        case .portrait: return 90
        case .portraitUpsideDown: return 270
        case .landscapeRight: return 180
        case .landscapeLeft: return 0
        }
    }

    static func stereoInputOrientation(for orientation: CaptureVideoOrientation) -> AVAudioSession.StereoOrientation {
        switch orientation {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeRight: return .landscapeRight
        case .landscapeLeft: return .landscapeLeft
        }
    }

    static func cachedStereoInputOrientation() -> AVAudioSession.StereoOrientation {
        stereoInputOrientation(for: cachedVideoOrientation())
    }

    @MainActor
    private static func interfaceOrientation() -> UIInterfaceOrientation {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.interfaceOrientation ?? .portrait
    }
}
