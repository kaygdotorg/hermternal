import Foundation
import os

/// Dual-sink logger: unified logging for `log stream`, plus a plain file.
///
/// The app normally runs via `open`, so stdout goes nowhere. A file sink
/// keeps auth and transport failures inspectable after the fact without
/// attaching a debugger.
enum Log {
    private static let logger = Logger(subsystem: "com.tavyg.hermternal", category: "app")

    /// `~/Library/Logs/Hermternal/hermternal.log`
    static let fileURL: URL = {
        let directory = FileManager.default
            .homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/Hermternal", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "hermternal.log")
    }()

    private static let queue = DispatchQueue(label: "com.tavyg.hermternal.log")

    // A value-type format style, unlike ISO8601DateFormatter, is Sendable
    // and so usable from a static context under strict concurrency.
    private static let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func info(_ message: String) { write("INFO", message) }
    static func error(_ message: String) { write("ERROR", message) }

    private static func write(_ level: String, _ message: String) {
        logger.log("\(level, privacy: .public) \(message, privacy: .public)")
        let line = "\(Date.now.formatted(timestamp)) \(level) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
