import Foundation

enum TemporaryCaptureStore {
    private static let directoryName = "alton-capture"

    static var directoryURL: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func photoURL() -> URL {
        directoryURL.appendingPathComponent("photo-\(UUID().uuidString).jpg")
    }

    static func videoURL() -> URL {
        directoryURL.appendingPathComponent("video-\(UUID().uuidString).mp4")
    }

    static func segmentURL(index: Int) -> URL {
        directoryURL.appendingPathComponent("segment-\(index)-\(UUID().uuidString).mp4")
    }

    static func voiceoverURL() -> URL {
        directoryURL.appendingPathComponent("voiceover-\(UUID().uuidString).m4a")
    }

    static func exportURL() -> URL {
        directoryURL.appendingPathComponent("export-\(UUID().uuidString).mp4")
    }

    static func isManaged(_ url: URL) -> Bool {
        directoryURL.path == url.deletingLastPathComponent().path
            || url.path.hasPrefix(directoryURL.path + "/")
    }

    static func removeItem(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func removeIfManaged(_ url: URL) {
        guard isManaged(url) else { return }
        removeItem(at: url)
    }

    /// Deletes managed files that are not in `keepURLs`.
    static func purgeUnreferenced(keeping keepURLs: Set<URL>) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else { return }

        let keepPaths = Set(keepURLs.filter(isManaged).map(\.path))
        for file in contents where !keepPaths.contains(file.path) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func purgeAll() {
        purgeUnreferenced(keeping: [])
    }

    /// Removes managed files older than `maxAge` (orphans after crashes / force-quit).
    static func purgeStale(maxAge: TimeInterval = 12 * 60 * 60) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-maxAge)
        for file in contents {
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate,
                  modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}
