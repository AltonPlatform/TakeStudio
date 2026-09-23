import AVFoundation
import UIKit

protocol CaptureLifecycleMonitorDelegate: AnyObject {
    func captureLifecycleMonitorDidInterruptSession(_ monitor: CaptureLifecycleMonitor)
    func captureLifecycleMonitorDidResumeSession(_ monitor: CaptureLifecycleMonitor)
}

final class CaptureLifecycleMonitor {
    weak var delegate: CaptureLifecycleMonitorDelegate?
    var automaticSessionControlEnabled = true

    private weak var session: AVCaptureSession?
    private let sessionQueue: DispatchQueue
    private var observers: [NSObjectProtocol] = []

    init(
        session: AVCaptureSession,
        sessionQueue: DispatchQueue,
        delegate: CaptureLifecycleMonitorDelegate
    ) {
        self.session = session
        self.sessionQueue = sessionQueue
        self.delegate = delegate
        installObservers()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func installObservers() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard self.automaticSessionControlEnabled else { return }
            if self.shouldIgnoreInterruption(notification) { return }
            self.delegate?.captureLifecycleMonitorDidInterruptSession(self)
        })

        observers.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            guard self?.automaticSessionControlEnabled == true else { return }
            self?.resumeSession()
        })

        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.pauseSession()
        })

        observers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resumeSession()
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if type == AVAudioSession.InterruptionType.ended.rawValue {
                self.resumeSession()
            }
        })
    }

    private func shouldIgnoreInterruption(_ notification: Notification) -> Bool {
        guard
            let reasonValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
            let reason = AVCaptureSession.InterruptionReason(rawValue: reasonValue)
        else { return false }

        switch reason {
        case .videoDeviceNotAvailableDueToSystemPressure:
            return false
        default:
            return false
        }
    }

    func resumeSession() {
        guard automaticSessionControlEnabled else { return }
        sessionQueue.async { [weak self] in
            guard let self, let session = self.session else { return }
            if !session.isRunning {
                session.startRunning()
            }
            DispatchQueue.main.async {
                self.delegate?.captureLifecycleMonitorDidResumeSession(self)
            }
        }
    }

    private func pauseSession() {
        guard automaticSessionControlEnabled else { return }
        sessionQueue.async { [weak self] in
            guard let self, let session = self.session, session.isRunning else { return }
            session.stopRunning()
            DispatchQueue.main.async {
                self.delegate?.captureLifecycleMonitorDidInterruptSession(self)
            }
        }
    }
}
