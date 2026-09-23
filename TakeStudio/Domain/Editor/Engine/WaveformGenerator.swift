import AVFoundation
import SwiftUI

struct WaveformSample: Sendable {
    let samples: [Float]
    let duration: TimeInterval
}

actor WaveformGenerator {
    static let shared = WaveformGenerator()

    private var cache: [String: WaveformSample] = [:]
    private var cacheOrder: [String] = []
    private let maxCacheEntries = 50
    private let maxCacheBytes = 20 * 1024 * 1024
    private var cacheBytes = 0

    func waveform(for url: URL, targetSamplesPerSecond: Int = 50) async throws -> WaveformSample {
        let key = url.path
        if let cached = cache[key] { return cached }

        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            let empty = WaveformSample(samples: [], duration: 0)
            store(empty, for: key)
            return empty
        }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(output)
        reader.startReading()

        let duration = try await asset.load(.duration).seconds
        let targetCount = max(1, Int(duration * Double(targetSamplesPerSecond)))
        var buckets = [Float](repeating: 0, count: targetCount)
        var bucketCounts = [Int](repeating: 0, count: targetCount)

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            var data = Data(count: length)
            data.withUnsafeMutableBytes { pointer in
                guard let base = pointer.baseAddress else { return }
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: base)
            }
            data.withUnsafeBytes { pointer in
                let samples = pointer.bindMemory(to: Int16.self)
                let totalSamples = samples.count
                guard totalSamples > 0 else { return }
                for index in stride(from: 0, to: totalSamples, by: 8) {
                    let progress = Double(index) / Double(totalSamples)
                    let bucketIndex = min(targetCount - 1, Int(progress * Double(targetCount)))
                    let value = abs(Float(samples[index]) / Float(Int16.max))
                    buckets[bucketIndex] = max(buckets[bucketIndex], value)
                    bucketCounts[bucketIndex] += 1
                }
            }
        }

        let result = WaveformSample(samples: buckets, duration: duration)
        store(result, for: key)
        return result
    }

    func clearCache() {
        cache.removeAll()
        cacheOrder.removeAll()
        cacheBytes = 0
    }

    private func store(_ sample: WaveformSample, for key: String) {
        let bytes = sample.samples.count * MemoryLayout<Float>.size
        if let existing = cache[key] {
            cacheBytes -= existing.samples.count * MemoryLayout<Float>.size
            cacheOrder.removeAll { $0 == key }
        }
        cache[key] = sample
        cacheOrder.append(key)
        cacheBytes += bytes

        while cacheOrder.count > maxCacheEntries || cacheBytes > maxCacheBytes, let oldest = cacheOrder.first {
            cacheOrder.removeFirst()
            if let removed = cache.removeValue(forKey: oldest) {
                cacheBytes -= removed.samples.count * MemoryLayout<Float>.size
            }
        }
    }
}

struct WaveformStripView: View {
    let sample: WaveformSample?
    let width: CGFloat
    let height: CGFloat
    var color: Color = .teal
    var opacity: Double = 0.85

    var body: some View {
        Canvas { context, size in
            guard let sample, !sample.samples.isEmpty else { return }
            let barCount = max(1, min(sample.samples.count, Int(size.width)))
            let bucketSize = Float(sample.samples.count) / Float(barCount)
            let barWidth = size.width / CGFloat(barCount)
            let midY = size.height / 2

            for index in 0..<barCount {
                let start = Int(Float(index) * bucketSize)
                let end = min(Int(Float(index + 1) * bucketSize), sample.samples.count)
                let slice = sample.samples[start..<end]
                let value = slice.max() ?? 0
                let barHeight = CGFloat(value) * midY
                let rect = CGRect(
                    x: CGFloat(index) * barWidth,
                    y: midY - barHeight,
                    width: max(barWidth - 0.5, 1),
                    height: barHeight * 2
                )
                context.fill(Path(rect), with: .color(color.opacity(opacity)))
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
