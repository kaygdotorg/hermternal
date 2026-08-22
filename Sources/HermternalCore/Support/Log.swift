import Foundation
import os

/// Dual-sink logger: unified logging for `log stream`, plus a plain file.
///
/// The app normally runs via `open`, so stdout goes nowhere. A file sink
/// keeps auth and transport failures inspectable after the fact without
/// attaching a debugger.
public enum Log {
    private static let logger = Logger(subsystem: AppIdentity.bundleID, category: "app")

    /// There is no cross-platform logs search path. Keep the plain file in
    /// app-owned application support instead of inventing a platform-specific
    /// library/logs location; iOS resolves this inside the app sandbox.
    public static func logsDirectory(applicationSupportDirectory: URL) -> URL {
        applicationSupportDirectory
            .appending(path: "Hermternal/logs", directoryHint: .isDirectory)
    }

    /// Pure path composition seam for platform adapters and tests.
    public static func fileURL(in directory: URL) -> URL {
        directory.appending(path: "hermternal.log")
    }

    /// Resolves and creates the log directory. An explicit directory bypasses
    /// standard-directory lookup for sandbox or file-protection adapters.
    public static func resolvedFileURL(
        directory override: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        let directory: URL
        if let override {
            directory = override
        } else {
            guard let applicationSupportDirectory = fileManager
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first
            else {
                return nil
            }
            directory = logsDirectory(applicationSupportDirectory: applicationSupportDirectory)
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return fileURL(in: directory)
    }

    public static let fileURL: URL? = resolvedFileURL()

    private static let queue = DispatchQueue(label: "\(AppIdentity.bundleID).log")

    // A value-type format style, unlike ISO8601DateFormatter, is Sendable
    // and so usable from a static context under strict concurrency.
    private static let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    public static func info(_ message: String) { write("INFO", message) }
    public static func error(_ message: String) { write("ERROR", message) }

    private static func write(_ level: String, _ message: String) {
        logger.log("\(level, privacy: .public) \(message, privacy: .public)")
        let line = "\(Date.now.formatted(timestamp)) \(level) \(message)\n"
        guard let fileURL else { return }
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
