import AVFoundation
import Foundation

enum SoundEffectCategory: String, CaseIterable, Identifiable, Sendable {
    case ui
    case whoosh
    case impact
    case ambient

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ui: return "UI"
        case .whoosh: return "Whoosh"
        case .impact: return "Impact"
        case .ambient: return "Ambient"
        }
    }
}

struct SoundEffect: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let category: SoundEffectCategory
    let frequency: Double
    let duration: TimeInterval
    let wave: SoundEffectWave

    static func == (lhs: SoundEffect, rhs: SoundEffect) -> Bool {
        lhs.id == rhs.id
    }
}

enum SoundEffectWave: Sendable {
    case sine
    case noise
    case sweep
}

enum SoundEffectLibrary {
    static let allEffects: [SoundEffect] = [
        SoundEffect(id: "pop", name: "Pop", category: .ui, frequency: 880, duration: 0.12, wave: .sine),
        SoundEffect(id: "click", name: "Click", category: .ui, frequency: 1200, duration: 0.06, wave: .sine),
        SoundEffect(id: "ding", name: "Ding", category: .ui, frequency: 660, duration: 0.35, wave: .sine),
        SoundEffect(id: "whoosh", name: "Whoosh", category: .whoosh, frequency: 220, duration: 0.45, wave: .sweep),
        SoundEffect(id: "swoosh", name: "Swoosh", category: .whoosh, frequency: 180, duration: 0.55, wave: .sweep),
        SoundEffect(id: "riser", name: "Riser", category: .whoosh, frequency: 140, duration: 0.8, wave: .sweep),
        SoundEffect(id: "impact", name: "Impact", category: .impact, frequency: 90, duration: 0.25, wave: .noise),
        SoundEffect(id: "thud", name: "Thud", category: .impact, frequency: 60, duration: 0.18, wave: .noise),
        SoundEffect(id: "sparkle", name: "Sparkle", category: .ambient, frequency: 1040, duration: 0.5, wave: .sine),
        SoundEffect(id: "chime", name: "Chime", category: .ambient, frequency: 784, duration: 0.6, wave: .sine)
    ]

    static func effects(in category: SoundEffectCategory) -> [SoundEffect] {
        allEffects.filter { $0.category == category }
    }

    static func effect(id: String) -> SoundEffect? {
        allEffects.first { $0.id == id }
    }
}

enum SoundEffectAudioGenerator {
    private static var cache: [String: URL] = [:]
    private static let lock = NSLock()

    static func url(for effect: SoundEffect) throws -> URL {
        lock.lock()
        if let cached = cache[effect.id] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let url = try render(effect: effect)
        lock.lock()
        cache[effect.id] = url
        lock.unlock()
        return url
    }

    private static func render(effect: SoundEffect) throws -> URL {
        let sampleRate = 44_100.0
        let frameCount = AVAudioFrameCount(sampleRate * effect.duration)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw SoundEffectError.renderFailed
        }
        buffer.frameLength = frameCount

        guard let channelData = buffer.floatChannelData?[0] else {
            throw SoundEffectError.renderFailed
        }

        let totalFrames = Int(frameCount)
        for frame in 0..<totalFrames {
            let progress = Double(frame) / Double(max(totalFrames - 1, 1))
            let envelope = exp(-progress * 4.0)
            let sample: Float
            switch effect.wave {
            case .sine:
                let frequency = effect.frequency
                sample = Float(sin(2 * Double.pi * frequency * Double(frame) / sampleRate)) * Float(envelope)
            case .noise:
                sample = Float.random(in: -1...1) * Float(envelope) * 0.35
            case .sweep:
                let start = effect.frequency * 0.5
                let end = effect.frequency * 3.0
                let frequency = start + (end - start) * progress
                sample = Float(sin(2 * Double.pi * frequency * Double(frame) / sampleRate)) * Float(envelope) * 0.8
            }
            channelData[frame] = sample
        }

        let destination = TemporaryCaptureStore.directoryURL
            .appendingPathComponent("sfx-\(effect.id)-\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: destination, settings: format.settings)
        try file.write(from: buffer)
        return destination
    }
}

enum SoundEffectError: LocalizedError {
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .renderFailed: return "Failed to render sound effect."
        }
    }
}
