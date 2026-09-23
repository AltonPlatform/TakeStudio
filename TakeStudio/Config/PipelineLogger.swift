import Foundation
import OSLog

/// Structured logging for camera → editor export pipeline.
enum PipelineLogger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.alton.takestudio"

    static let editor = Logger(subsystem: subsystem, category: "Editor")
    static let media = Logger(subsystem: subsystem, category: "Media")
    static let camera = Logger(subsystem: subsystem, category: "Camera")

    static func logError(_ logger: Logger, _ message: String, error: Error, file: String = #fileID, line: Int = #line) {
        let ns = error as NSError
        logger.error(
            "\(message, privacy: .public) domain=\(ns.domain, privacy: .public) code=\(ns.code) desc=\(ns.localizedDescription, privacy: .public) @\(file, privacy: .public):\(line)"
        )
        if !ns.userInfo.isEmpty {
            logger.debug("userInfo=\(String(describing: ns.userInfo), privacy: .public)")
        }
        CrashReporting.record(error, message: message, file: file, line: line)
        CrashReporting.log("\(message) domain=\(ns.domain) code=\(ns.code)")
    }

    static func fileSummary(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        let size = values?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "?"
        let exists = FileManager.default.fileExists(atPath: url.path)
        return "path=\(url.lastPathComponent) exists=\(exists) size=\(size)"
    }
}
