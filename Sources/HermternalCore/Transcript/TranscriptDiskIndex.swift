import Foundation

/// File operations required by the store. Tests use the deterministic memory implementation.
public protocol TranscriptFileSystem: Sendable {
    func data(at url: URL) throws -> Data
    func write(_ data: Data, to url: URL) throws
    func remove(_ url: URL) throws
    func move(_ source: URL, to destination: URL) throws
    func exists(_ url: URL) -> Bool
    func createDirectory(_ url: URL) throws
}

public struct LocalTranscriptFileSystem: TranscriptFileSystem, Sendable {
    public init() {}
    public func data(at url: URL) throws -> Data { try Data(contentsOf: url) }
    public func remove(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
    public func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
    }
    public func move(_ source: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
        } else {
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }
    public func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    public func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

/// A deterministic, thread-safe file system for store tests.
public final class InMemoryTranscriptFileSystem: TranscriptFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var directories: Set<String> = []

    public init() {}

    public func data(at url: URL) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let value = files[url.standardizedFileURL.path] else { throw CocoaError(.fileNoSuchFile) }
        return value
    }
    public func write(_ data: Data, to url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        files[url.standardizedFileURL.path] = data
    }
    public func remove(_ url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        files.removeValue(forKey: url.standardizedFileURL.path)
    }
    public func move(_ source: URL, to destination: URL) throws {
        lock.lock(); defer { lock.unlock() }
        let sourcePath = source.standardizedFileURL.path
        guard let value = files.removeValue(forKey: sourcePath) else { throw CocoaError(.fileNoSuchFile) }
        files[destination.standardizedFileURL.path] = value
    }
    public func exists(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return files[url.standardizedFileURL.path] != nil || directories.contains(url.standardizedFileURL.path)
    }
    public func createDirectory(_ url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        directories.insert(url.standardizedFileURL.path)
    }

}

public struct TranscriptManifest: Codable, Hashable, Sendable {
    public static let currentVersion = 1
    public let version: Int
    public let generation: UInt64
    public let epoch: UInt64
    public let rowCount: Int
    public let messageCount: Int
    public let exactCount: Bool

    public init(
        version: Int = TranscriptManifest.currentVersion,
        generation: UInt64 = 0,
        epoch: UInt64 = 0,
        rowCount: Int = 0,
        messageCount: Int = 0,
        exactCount: Bool = true
    ) {
        self.version = version
        self.generation = generation
        self.epoch = epoch
        self.rowCount = rowCount
        self.messageCount = messageCount
        self.exactCount = exactCount
    }
}

/// Persistent message-to-row locations. The dictionary contains metadata only.
public struct TranscriptDiskIndex: Codable, Hashable, Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public let messageID: String
        public let recordOffset: UInt64
        public let recordLength: UInt64
        public let firstOrdinal: Int
        public let rowCount: Int
        public let revision: UInt64

        public init(messageID: String, recordOffset: UInt64, recordLength: UInt64, firstOrdinal: Int, rowCount: Int, revision: UInt64) {
            self.messageID = messageID
            self.recordOffset = recordOffset
            self.recordLength = recordLength
            self.firstOrdinal = firstOrdinal
            self.rowCount = rowCount
            self.revision = revision
        }
    }

    internal let entries: [String: Entry]
    internal let descriptors: [TranscriptRowDescriptor]
    /// Full-order marker metadata. Older indexes omit this value.
    internal let modelSwitches: [TranscriptModelSwitchMarker]?
    /// Stable wire order. Older indexes derive order from entry ordinals.
    internal let orderedMessageIDs: [String]?
    /// Compact turn spans. Older indexes build this once during load.
    internal let turns: [TranscriptTurnIndexEntry]?
    public init(
        entries: [String: Entry] = [:],
        descriptors: [TranscriptRowDescriptor] = [],
        modelSwitches: [TranscriptModelSwitchMarker]? = nil,
        orderedMessageIDs: [String]? = nil,
        turns: [TranscriptTurnIndexEntry]? = nil
    ) {
        self.entries = entries
        self.descriptors = descriptors
        self.modelSwitches = modelSwitches
        self.orderedMessageIDs = orderedMessageIDs
        self.turns = turns
    }

    public func locate(messageID: String) -> RowLocation? {
        guard let entry = entries[messageID], entry.rowCount > 0 else { return nil }
        return RowLocation(ordinal: entry.firstOrdinal, rowCount: entry.rowCount)
    }
}

public struct RowLocation: Codable, Hashable, Sendable {
    public let ordinal: Int
    public let rowCount: Int

    public init(ordinal: Int, rowCount: Int = 1) {
        precondition(ordinal >= 0 && rowCount >= 1)
        self.ordinal = ordinal
        self.rowCount = rowCount
    }
    public var range: Range<Int> { ordinal..<(ordinal + rowCount) }
}
