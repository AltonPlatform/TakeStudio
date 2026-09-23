import AVFoundation
import UIKit

final class PhotoCaptureProcessor: NSObject {
    private let photoOutput = AVCapturePhotoOutput()
    private var continuation: CheckedContinuation<URL, Error>?

    func configure(session: AVCaptureSession) throws {
        guard !session.outputs.contains(where: { $0 === photoOutput }) else { return }
        guard session.canAddOutput(photoOutput) else {
            throw CaptureError.configurationFailed
        }
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .quality
    }

    func capture(flashMode: CameraFlashMode, mirrored: Bool) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            let settings = AVCapturePhotoSettings()
            if photoOutput.supportedFlashModes.contains(flashMode.avFlashMode) {
                settings.flashMode = flashMode.avFlashMode
            }

            if let connection = photoOutput.connection(with: .video) {
                connection.isVideoMirrored = mirrored
            }

            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }
}

extension PhotoCaptureProcessor: AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
            return
        }

        let url = TemporaryCaptureStore.photoURL()
        do {
            guard let data = photo.fileDataRepresentation() else {
                throw CaptureError.photoCaptureFailed
            }
            try data.write(to: url)
            continuation?.resume(returning: url)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }
}
