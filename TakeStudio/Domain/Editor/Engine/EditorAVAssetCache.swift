import AVFoundation
import Foundation

enum EditorBuildQuality {
    case preview
    case export
}

/// Pool for reusing `AVURLAsset` instances. Named distinctly to avoid clashing with AVFoundation's `AVAssetCache`.
final class EditorAVAssetCache: @unchecked Sendable {
    static let shared = EditorAVAssetCache()

    private let lock = NSLock()
    private var assets: [String: AVURLAsset] = [:]
    private var accessOrder: [String] = []
    private let maxEntries = 12

    func asset(for url: URL) -> AVURLAsset {
        let key = url.path
        lock.lock()
        defer { lock.unlock() }
        if let cached = assets[key] {
            touch(key)
            return cached
        }
        let asset = AVURLAsset(url: url)
        assets[key] = asset
        touch(key)
        trimIfNeeded()
        return asset
    }

    func removeAsset(for url: URL) {
        lock.lock()
        assets.removeValue(forKey: url.path)
        accessOrder.removeAll { $0 == url.path }
        lock.unlock()
    }

    func purgeUnreferenced(keeping urls: Set<URL>) {
        let keepPaths = Set(urls.map(\.path))
        lock.lock()
        let stale = assets.keys.filter { !keepPaths.contains($0) }
        for key in stale {
            assets.removeValue(forKey: key)
            accessOrder.removeAll { $0 == key }
        }
        lock.unlock()
    }

    func clearAll() {
        lock.lock()
        assets.removeAll()
        accessOrder.removeAll()
        lock.unlock()
    }

    private func touch(_ key: String) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    private func trimIfNeeded() {
        while assets.count > maxEntries, let oldest = accessOrder.first {
            accessOrder.removeFirst()
            assets.removeValue(forKey: oldest)
        }
    }
}
