import Foundation

/// Fixed workload used by memory contracts. It contains no network, timers, or
/// random values, so every admission and eviction result is reproducible.
public enum WorstTranscriptFixture {
    public static let version = "worst-v1"
    public static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    public struct Configuration: Sendable, Equatable {
        public let sessionCount: Int
        public let folderCount: Int
        public let attachmentCount: Int
        public let thumbnailBytes: Int
        public let audioPCMBytes: Int
        public let switchCount: Int

        public init(
            sessionCount: Int = 10_000,
            folderCount: Int = 1_000,
            attachmentCount: Int = 8,
            thumbnailBytes: Int = 2 * 1_048_576,
            audioPCMBytes: Int = 1 * 1_048_576,
            switchCount: Int = 20
        ) {
            precondition(sessionCount >= 0 && folderCount >= 0)
            precondition(attachmentCount >= 0 && thumbnailBytes >= 0 && audioPCMBytes >= 0)
            precondition(switchCount >= 0)
            self.sessionCount = sessionCount
            self.folderCount = folderCount
            self.attachmentCount = attachmentCount
            self.thumbnailBytes = thumbnailBytes
            self.audioPCMBytes = audioPCMBytes
            self.switchCount = switchCount
        }

        public static let worstV1 = Configuration()
    }

    public struct FileBackedAttachment: Identifiable, Hashable, Sendable {
        public let id: String
        public let fileURL: URL
        public let byteCount: Int

        public init(id: String, fileURL: URL, byteCount: Int) {
            precondition(byteCount >= 0)
            self.id = id
            self.fileURL = fileURL
            self.byteCount = byteCount
        }
    }

    public struct HeadTailScrollFake: Sendable, Equatable {
        public private(set) var headVisits = 0
        public private(set) var tailVisits = 0

        public init() {}

        public mutating func visitHead() { headVisits += 1 }
        public mutating func visitTail() { tailVisits += 1 }
    }

    public struct SearchFindFake: Sendable, Equatable {
        public private(set) var searchQueries = 0
        public private(set) var findQueries = 0

        public init() {}

        public mutating func search() { searchQueries += 1 }
        public mutating func find() { findQueries += 1 }
    }

    public struct StreamingFake: Sendable, Equatable {
        public private(set) var chunks = 0
        public private(set) var stalePublications = 0

        public init() {}

        public mutating func receiveChunk() { chunks += 1 }
        public mutating func rejectStalePublication() { stalePublications += 1 }
    }

    public struct State: Sendable {
        public let sessions: [ChatSession]
        public let folders: [Folder]
        public let membership: [String: String]
        public let attachments: [FileBackedAttachment]
        public let thumbnailBytes: Int
        public let audioPCMBytes: Int
        public var scroll: HeadTailScrollFake
        public var searchFind: SearchFindFake
        public var streaming: StreamingFake
        public let switches: Int

        public init(configuration: Configuration = .worstV1, root: URL) {
            sessions = (0..<configuration.sessionCount).map { index in
                ChatSession(from: .object([
                    "id": .string("worst-session-\(index)"),
                    "title": .string("Worst transcript session \(index)"),
                    "preview": .string("Deterministic fixture row \(index)"),
                    "started_at": .number(WorstTranscriptFixture.fixedDate.timeIntervalSince1970 - Double(index)),
                    "last_active": .number(WorstTranscriptFixture.fixedDate.timeIntervalSince1970 - Double(index)),
                    "pinned": .bool(index.isMultiple(of: 97)),
                    "archived": .bool(false),
                    "source": .string("chat"),
                    "profile": .string("worst-v1"),
                    "message_count": .integer(Int64(index % 512))
                ]))
            }
            folders = (0..<configuration.folderCount).map { index in
                Folder(id: "worst-folder-\(index)", name: "Worst folder \(index)", order: index)
            }
            membership = configuration.folderCount == 0
                ? [:]
                : Dictionary(uniqueKeysWithValues: (0..<configuration.sessionCount).map { index in
                    ("worst-session-\(index)", "worst-folder-\(index % configuration.folderCount)")
                })
            attachments = (0..<configuration.attachmentCount).map { index in
                FileBackedAttachment(
                    id: "worst-attachment-\(index)",
                    fileURL: root.appending(path: "attachment-\(index).bin"),
                    byteCount: 2 * 1_048_576
                )
            }
            thumbnailBytes = configuration.thumbnailBytes
            audioPCMBytes = configuration.audioPCMBytes
            scroll = HeadTailScrollFake()
            searchFind = SearchFindFake()
            streaming = StreamingFake()
            switches = configuration.switchCount
        }
    }
    public struct Report: Sendable, Equatable {
        public let fixtureVersion: String
        public let profile: AppMemoryProfile
        public let metrics: AppMemoryMetrics
        public let sessionCount: Int
        public let folderCount: Int
        public let attachmentCount: Int
        public let attachmentsAreFileBacked: Bool
        public let thumbnailBytes: Int
        public let audioPCMBytes: Int
        public let residentAttachmentDataCount: Int
        public let headVisits: Int
        public let tailVisits: Int
        public let searchQueries: Int
        public let findQueries: Int
        public let switchCount: Int
        public let streamChunks: Int
        public let stalePublications: Int
        public let settledResidentBytes: Int
        public let settledGrowthBytes: Int
        public let settledGrowthLimitBytes: Int

        public var everyCategoryWithinEnvelope: Bool {
            metrics.categories.allSatisfy { category, value in
                value.residentBytes <= value.limitBytes && value.peakBytes <= value.limitBytes
            }
        }

        public var withinProfileEnvelope: Bool {
            metrics.residentBytes <= profile.totalBytes && metrics.peakBytes <= profile.totalBytes
        }
    }

    /// Builds the complete deterministic workload and records all resident
    /// categories. Attachments stay file-backed and contribute only metadata.
    public static func run(
        profile: AppMemoryProfile = .mac440MiB,
        configuration: Configuration = .worstV1,
        root: URL = FileManager.default.temporaryDirectory
            .appending(path: "HermternalWorstTranscriptFixture")
    ) -> Report {
        let state = State(configuration: configuration, root: root)
        let registry = AppMemoryRegistry(profile: profile)
        var admissions: [AppMemoryAdmission] = []
        admissions.reserveCapacity(AppMemoryCategory.allCases.count)

        func admit(_ category: AppMemoryCategory, _ bytes: Int) {
            if let admission = registry.admit(category: category, bytes: bytes) {
                admissions.append(admission)
            }
        }

        admit(.activeTranscript, profile.limit(for: .activeTranscript))
        admit(.preparedContent, profile.limit(for: .preparedContent))
        admit(.find, profile.limit(for: .find))
        admit(.search, profile.limit(for: .search))
        admit(.sidebar, profile.limit(for: .sidebar))
        admit(.prefetch, profile.limit(for: .prefetch))
        // Only attachment metadata is resident. The file payload is never a
        // Data value in fixture.
        let attachmentMetadata = state.attachments.count.multipliedReportingOverflow(by: 512)
        let attachmentMetadataBytes = attachmentMetadata.overflow ? Int.max : attachmentMetadata.partialValue
        admit(.attachments, min(profile.limit(for: .attachments), attachmentMetadataBytes))
        admit(.thumbnails, min(profile.limit(for: .thumbnails), state.thumbnailBytes))
        admit(.audioPCM, min(profile.limit(for: .audioPCM), state.audioPCMBytes))
        admit(.other, 0)

        var scroll = state.scroll
        scroll.visitHead()
        scroll.visitTail()
        var searchFind = state.searchFind
        searchFind.search()
        searchFind.find()
        var streaming = state.streaming
        for _ in 0..<configuration.switchCount {
            streaming.receiveChunk()
        }

        let metrics = registry.metrics()
        for admission in admissions {
            registry.release(admission)
        }
        let settled = registry.metrics()
        return Report(
            fixtureVersion: version,
            profile: profile,
            metrics: metrics,
            sessionCount: state.sessions.count,
            folderCount: state.folders.count,
            attachmentCount: state.attachments.count,
            attachmentsAreFileBacked: state.attachments.allSatisfy { $0.fileURL.isFileURL },
            thumbnailBytes: state.thumbnailBytes,
            audioPCMBytes: state.audioPCMBytes,
            residentAttachmentDataCount: 0,
            headVisits: scroll.headVisits,
            tailVisits: scroll.tailVisits,
            searchQueries: searchFind.searchQueries,
            findQueries: searchFind.findQueries,
            switchCount: state.switches,
            streamChunks: streaming.chunks,
            stalePublications: streaming.stalePublications,
            settledResidentBytes: settled.residentBytes,
            settledGrowthBytes: settled.residentBytes,
            settledGrowthLimitBytes: settledGrowthLimit(for: profile)
        )
    }

    public static func settledGrowthLimit(for profile: AppMemoryProfile) -> Int {
        switch profile.totalBytes {
        case 100 * 1_048_576: return 16 * 1_048_576
        case 216 * 1_048_576: return 24 * 1_048_576
        default: return 32 * 1_048_576
        }
    }
}
