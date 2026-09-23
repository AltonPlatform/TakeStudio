import AVFoundation

struct ZoomStop: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let factor: CGFloat
}

final class CaptureDeviceManager {
    private(set) var position: AVCaptureDevice.Position = .back
    private(set) var currentDevice: AVCaptureDevice?
    private var exposureLockWorkItem: DispatchWorkItem?

    var minZoomFactor: CGFloat {
        currentDevice?.minAvailableVideoZoomFactor ?? 1.0
    }

    var maxZoomFactor: CGFloat {
        guard let device = currentDevice else { return 5.0 }
        return min(device.maxAvailableVideoZoomFactor, 10.0)
    }

    var zoomFactor: CGFloat {
        currentDevice?.videoZoomFactor ?? 1.0
    }

    var hasFlash: Bool {
        currentDevice?.hasFlash == true
    }

    var hasTorch: Bool {
        currentDevice?.hasTorch == true
    }

    var zoomStops: [ZoomStop] {
        guard let device = currentDevice, position == .back else {
            return [ZoomStop(id: "1", label: "1×", factor: 1.0)]
        }

        var stops: [ZoomStop] = []
        let minZoom = device.minAvailableVideoZoomFactor

        if minZoom < 0.9 {
            stops.append(ZoomStop(id: "0.5", label: "0.5×", factor: minZoom))
        }

        stops.append(ZoomStop(id: "1", label: "1×", factor: max(1.0, minZoom)))

        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        for factor in switchOvers where factor > 1.0 {
            let label = factor.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(factor))×"
                : String(format: "%.1f×", factor)
            stops.append(ZoomStop(id: String(format: "%.2f", factor), label: label, factor: factor))
        }

        if stops.count == 1, maxZoomFactor >= 2 {
            stops.append(ZoomStop(id: "2", label: "2×", factor: min(2.0, maxZoomFactor)))
        }

        var unique: [ZoomStop] = []
        for stop in stops {
            if !unique.contains(where: { abs($0.factor - stop.factor) < 0.05 }) {
                unique.append(stop)
            }
        }
        return unique.sorted { $0.factor < $1.factor }
    }

    func selectDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        cancelScheduledExposureLock()
        self.position = position
        let device: AVCaptureDevice?

        if position == .back {
            device = Self.discoverBackCamera()
        } else {
            device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        }

        currentDevice = device
        restoreContinuousExposureAndWhiteBalance()
        return device
    }

    func scheduleAutoExposureAndWhiteBalanceLock(after delay: TimeInterval = 1.0) {
        cancelScheduledExposureLock()
        let work = DispatchWorkItem { [weak self] in
            try? self?.lockExposureAndWhiteBalance()
        }
        exposureLockWorkItem = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay, execute: work)
    }

    func cancelScheduledExposureLock() {
        exposureLockWorkItem?.cancel()
        exposureLockWorkItem = nil
    }

    private func restoreContinuousExposureAndWhiteBalance() {
        guard let device = currentDevice else { return }
        try? device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
    }

    private func lockExposureAndWhiteBalance() throws {
        guard let device = currentDevice else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if device.isExposureModeSupported(.locked) {
            device.exposureMode = .locked
        }
        if device.isWhiteBalanceModeSupported(.locked) {
            device.whiteBalanceMode = .locked
        }
    }

    func setZoomFactor(_ factor: CGFloat, rampRate: Float = 8.0) throws {
        guard let device = currentDevice else { return }
        let clamped = min(max(factor, device.minAvailableVideoZoomFactor), min(device.maxAvailableVideoZoomFactor, 10.0))

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.ramp(toVideoZoomFactor: clamped, withRate: rampRate)
    }

    func setFocus(at normalizedPoint: CGPoint, lock: Bool) throws {
        guard let device = currentDevice else { return }

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        if device.isFocusPointOfInterestSupported {
            device.focusPointOfInterest = normalizedPoint
            device.focusMode = lock ? .locked : .continuousAutoFocus
        }

        if device.isExposurePointOfInterestSupported {
            device.exposurePointOfInterest = normalizedPoint
            device.exposureMode = lock ? .locked : .continuousAutoExposure
        }
    }

    var minExposureBias: Float {
        currentDevice?.minExposureTargetBias ?? -2
    }

    var maxExposureBias: Float {
        currentDevice?.maxExposureTargetBias ?? 2
    }

    var currentExposureBias: Float {
        currentDevice?.exposureTargetBias ?? 0
    }

    func setExposureBias(_ bias: Float) throws {
        guard let device = currentDevice else { return }
        let clamped = min(max(bias, device.minExposureTargetBias), device.maxExposureTargetBias)

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        if device.exposureMode != .locked,
           device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }

        device.setExposureTargetBias(clamped, completionHandler: nil)
    }

    func resetExposureBias() throws {
        try setExposureBias(0)
    }

    func setTorchEnabled(_ enabled: Bool) throws {
        guard let device = currentDevice, device.hasTorch else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.torchMode = enabled ? .on : .off
    }

    func setFrameRate(_ frameRate: Int32, session: AVCaptureSession) throws {
        guard let device = currentDevice else { return }

        let clampedRate = Self.clampFrameRate(frameRate, for: device)
        let duration = CMTime(value: 1, timescale: clampedRate)

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
    }

    func maxSupportedFrameRate() -> Int32 {
        guard let device = currentDevice else { return 30 }
        let maxRate = device.activeFormat.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
        return Int32(maxRate.rounded(.down))
    }

    private static func clampFrameRate(_ frameRate: Int32, for device: AVCaptureDevice) -> Int32 {
        let ranges = device.activeFormat.videoSupportedFrameRateRanges
        guard !ranges.isEmpty else { return max(frameRate, 1) }

        let minAllowed = Int32(ranges.map(\.minFrameRate).min()!.rounded(.up))
        let maxAllowed = Int32(ranges.map(\.maxFrameRate).max()!.rounded(.down))
        return min(max(frameRate, minAllowed), maxAllowed)
    }

    private static func discoverBackCamera() -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera,
            .builtInWideAngleCamera
        ]
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .back
        )
        return session.devices.first ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }
}
