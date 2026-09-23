import Foundation

/// No-op crash reporting stub (standalone build has no Firebase Crashlytics).
enum CrashReporting {
    static func record(_ error: Error, message: String, file: String = #fileID, line: Int = #line) {}
    static func log(_ message: String) {}
}
