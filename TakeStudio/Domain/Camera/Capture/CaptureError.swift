import Foundation

enum CaptureError: LocalizedError {
    case permissionDenied(Permission)
    case configurationFailed
    case deviceUnavailable
    case photoCaptureFailed
    case recordingFailed
    case recordingTooShort
    case notConfigured
    case sessionInterrupted
    case microphoneUnavailable

    enum Permission {
        case camera
        case microphone
    }

    var errorDescription: String? {
        switch self {
        case .permissionDenied(.camera):
            return "Camera access is required. Enable it in Settings."
        case .permissionDenied(.microphone):
            return "Microphone access is required for video recording. Enable it in Settings."
        case .configurationFailed:
            return "Unable to configure the camera."
        case .deviceUnavailable:
            return "No camera is available on this device."
        case .photoCaptureFailed:
            return "Unable to capture photo."
        case .recordingFailed:
            return "Unable to record video."
        case .recordingTooShort:
            return "Recording was too short. Hold the button a little longer."
        case .notConfigured:
            return "Camera is not ready yet."
        case .sessionInterrupted:
            return "Camera was interrupted. Tap to resume."
        case .microphoneUnavailable:
            return "Microphone is unavailable for recording."
        }
    }
}
