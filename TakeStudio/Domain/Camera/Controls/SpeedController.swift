import AVFoundation

struct SpeedController {
    var speed: CaptureSpeed = .normal

    private static let cycleOrder: [CaptureSpeed] = [
        .normal, .double, .quadruple, .half, .quarter
    ]

    mutating func cycle() {
        guard let index = Self.cycleOrder.firstIndex(of: speed) else {
            speed = .normal
            return
        }
        speed = Self.cycleOrder[(index + 1) % Self.cycleOrder.count]
    }
}
