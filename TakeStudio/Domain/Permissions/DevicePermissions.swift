import AVFoundation
import Contacts
import CoreBluetooth
import Photos
import Speech
import UIKit
import UserNotifications

enum DevicePermissions {
    struct CaptureAccess: Sendable {
        let camera: Bool
        let microphone: Bool

        var isReadyForRecording: Bool { camera && microphone }
    }

    static func requestCameraAccess() async -> Bool {
        await requestMediaAccess(for: .video)
    }

    static func requestCaptureAccess(includeMicrophone: Bool) async -> CaptureAccess {
        let camera = await requestCameraAccess()
        let microphone: Bool
        if includeMicrophone {
            microphone = await requestMicrophoneAccess()
            if microphone {
                requestBluetoothAccess()
            }
        } else {
            microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
        return CaptureAccess(camera: camera, microphone: microphone)
    }

    static func requestMicrophoneAccess() async -> Bool {
        await requestMediaAccess(for: .audio)
    }

    @discardableResult
    static func requestSpeechRecognitionAccess() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { newStatus in
                    continuation.resume(returning: newStatus == .authorized)
                }
            }
        default:
            return false
        }
    }

    @discardableResult
    static func requestPhotoLibraryAccess() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let newStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            return newStatus == .authorized || newStatus == .limited
        default:
            return false
        }
    }

    @discardableResult
    static func requestContactsAccess() async -> Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
        default:
            return false
        }
    }

    @discardableResult
    static func requestNotificationAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    static func registerForRemoteNotificationsIfAuthorized() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }
        await MainActor.run {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    static func requestBluetoothAccess() {
        BluetoothPermissionTrigger.shared.activate()
    }

    static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private static func requestMediaAccess(for mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: mediaType)
        default:
            return false
        }
    }
}

enum PhotoLibraryExporter {
    enum SaveError: LocalizedError {
        case permissionDenied
        case saveFailed

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Photo library access is required to save videos."
            case .saveFailed:
                return "Could not save video to Photos."
            }
        }
    }

    static func saveVideo(at url: URL) async throws {
        guard await DevicePermissions.requestPhotoLibraryAccess() else {
            throw SaveError.permissionDenied
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }, completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? SaveError.saveFailed)
                }
            })
        }
    }
}

private final class BluetoothPermissionTrigger: NSObject, CBCentralManagerDelegate {
    static let shared = BluetoothPermissionTrigger()

    private var manager: CBCentralManager?

    func activate() {
        guard manager == nil else { return }
        manager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {}
}
