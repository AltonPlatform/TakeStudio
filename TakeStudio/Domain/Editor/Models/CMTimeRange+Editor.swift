import AVFoundation

extension CMTimeRange {
    var endTime: CMTime {
        CMTimeAdd(start, duration)
    }

    var endSeconds: TimeInterval {
        endTime.seconds
    }

    static func from(start: CMTime, end: CMTime) -> CMTimeRange {
        CMTimeRange(start: start, end: end)
    }
}
