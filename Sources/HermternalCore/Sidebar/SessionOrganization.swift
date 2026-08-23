import Foundation

/// Local sidebar organization that is safe to move between machines.
public struct SessionOrganization: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public struct Grouping: Codable, Equatable, Sendable {
        public let byDate: Bool

        public init(byDate: Bool = true) {
            self.byDate = byDate
        }
    }

    public struct Sort: Codable, Equatable, Sendable {
        public let mode: SortMode

        public init(mode: SortMode = .lastActivity) {
            self.mode = mode
        }

        private enum CodingKeys: String, CodingKey {
            case mode
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard let rawMode = try container.decodeIfPresent(String.self, forKey: .mode),
                  let mode = SortMode(rawValue: rawMode)
            else {
                throw SessionOrganizationError.malformedConfiguration("sort.mode must be one of lastActivity, created, or title")
            }
            self.mode = mode
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(mode.rawValue, forKey: .mode)
        }
    }

    public struct Gateway: Codable, Equatable, Sendable {
        public let folderMembership: [String: String]

        public init(folderMembership: [String: String] = [:]) {
            self.folderMembership = folderMembership
        }
    }

    public let schemaVersion: Int
    public let grouping: Grouping
    public let sort: Sort
    public let folders: [Folder]
    public let gateways: [String: Gateway]

    public init(
        grouping: Grouping = Grouping(),
        sort: Sort = Sort(),
        folders: [Folder] = [],
        gateways: [String: Gateway] = [:]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.grouping = grouping
        self.sort = sort
        self.folders = folders
        self.gateways = gateways
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case grouping
        case sort
        case folders
        case gateways
    }

    public init(from decoder: Decoder) throws {
        do {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) else {
                throw SessionOrganizationError.malformedConfiguration("Missing schemaVersion")
            }
            guard version == Self.currentSchemaVersion else {
                throw SessionOrganizationError.unsupportedSchemaVersion(version)
            }

            self.schemaVersion = version
            self.grouping = try container.decodeIfPresent(Grouping.self, forKey: .grouping) ?? Grouping()
            self.sort = try container.decodeIfPresent(Sort.self, forKey: .sort) ?? Sort()
            self.folders = try container.decodeIfPresent([Folder].self, forKey: .folders) ?? []
            self.gateways = try container.decodeIfPresent([String: Gateway].self, forKey: .gateways) ?? [:]
        } catch let error as SessionOrganizationError {
            throw error
        } catch {
            throw SessionOrganizationError.malformedConfiguration("Invalid configuration: \(error)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(grouping, forKey: .grouping)
        try container.encode(sort, forKey: .sort)
        try container.encode(folders, forKey: .folders)
        try container.encode(gateways, forKey: .gateways)
    }
}
/// Folder's stored shape is already the organization schema. Add Codable at the
/// existing type boundary instead of introducing a second folder value type.
extension Folder: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case order
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            order: try container.decode(Int.self, forKey: .order)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(order, forKey: .order)
    }
}

public enum SessionOrganizationError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case malformedConfiguration(String)
    case fileReadFailed(String)
    case fileWriteFailed(String)
    case folderNotFound(String)
    case invalidFolderOrder
}
