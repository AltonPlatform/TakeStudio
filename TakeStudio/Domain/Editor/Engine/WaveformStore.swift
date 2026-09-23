import Foundation
import Observation

@MainActor
@Observable
final class WaveformStore {
    /// Thin view of WaveformGenerator cache — keeps a bounded local index for UI binding.
    private(set) var samples: [String: WaveformSample] = [:]
    private var loadingKeys = Set<String>()
    private var accessOrder: [String] = []
    private let maxEntries = 20

    func sample(for url: URL?) -> WaveformSample? {
        guard let url else { return nil }
        let key = url.path
        if let sample = samples[key] {
            touch(key)
            return sample
        }
        return nil
    }

    func loadIfNeeded(for url: URL) async {
        let key = url.path
        guard samples[key] == nil, !loadingKeys.contains(key) else { return }
        loadingKeys.insert(key)
        defer { loadingKeys.remove(key) }

        if let sample = try? await WaveformGenerator.shared.waveform(for: url) {
            samples[key] = sample
            touch(key)
            trimIfNeeded()
        }
    }

    func clear() {
        samples.removeAll()
        loadingKeys.removeAll()
        accessOrder.removeAll()
    }

    private func touch(_ key: String) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    private func trimIfNeeded() {
        while samples.count > maxEntries, let oldest = accessOrder.first {
            accessOrder.removeFirst()
            samples.removeValue(forKey: oldest)
        }
    }
}
