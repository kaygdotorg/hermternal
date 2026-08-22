import Foundation

/// Stable identity for an optional product capability.
public struct CapabilityID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}

/// Runtime state reported by the capability composition root.
public enum CapabilityState: Equatable, Codable, Sendable {
    /// The optional adapter is installed and active.
    case available
    /// The capability is known to the product but its adapter was omitted.
    case omitted
    /// The adapter was selected but cannot run in this environment.
    case unavailable(reason: String)

    public var reason: String? {
        guard case let .unavailable(reason) = self else { return nil }
        return reason
    }

    public var label: String {
        switch self {
        case .available: "Available"
        case .omitted: "Omitted"
        case .unavailable: "Unavailable"
        }
    }
}

/// Where the optional adapter is supplied from.
public enum CapabilityImplementationSource: String, CaseIterable, Codable, Sendable {
    case builtIn = "Built-in"
    case platformAdapter = "Platform adapter"
    case external = "External"
}

/// Origin used to protect the registry boundary. Core modules are not
/// capabilities and are rejected by ``CapabilityRegistry.register(_:)``.
public enum CapabilityOrigin: String, Codable, Sendable {
    case optionalCapability
    case coreModule
}

public struct CapabilityDescriptor: Identifiable, Equatable, Codable, Sendable {
    public let id: CapabilityID
    public let name: String
    public let purpose: String
    public let state: CapabilityState
    public let implementationSource: CapabilityImplementationSource
    public let dependencies: [CapabilityID]
    /// A non-nil note means changing this capability requires a relaunch.
    /// The registry does not offer a toggle unless a future adapter supplies
    /// a separate, runtime-safe control seam.
    public let relaunchNote: String?
    public let origin: CapabilityOrigin

    public init(
        id: CapabilityID,
        name: String,
        purpose: String,
        state: CapabilityState,
        implementationSource: CapabilityImplementationSource,
        dependencies: [CapabilityID] = [],
        relaunchNote: String? = nil,
        origin: CapabilityOrigin = .optionalCapability
    ) {
        self.id = id
        self.name = name
        self.purpose = purpose
        self.state = state
        self.implementationSource = implementationSource
        self.dependencies = dependencies
        self.relaunchNote = relaunchNote
        self.origin = origin
    }
}

public enum CapabilityRegistrationError: Error, Equatable, Sendable {
    case coreModule(CapabilityID)
    case duplicate(CapabilityID)
}

/// An injected, deterministic collection of optional capability descriptors.
///
/// Registry order is canonicalized by stable identifier rather than by the
/// order in which the composition root discovers adapters. This keeps the
/// Settings page and policy tests deterministic across launch environments.
public struct CapabilityRegistry: Equatable, Sendable {
    private var entries: [CapabilityDescriptor] = []

    public init() {}

    public init(capabilities: [CapabilityDescriptor]) throws {
        self.init()
        try register(contentsOf: capabilities)
    }

    public var capabilities: [CapabilityDescriptor] {
        entries.sorted { lhs, rhs in
            if lhs.id.rawValue != rhs.id.rawValue {
                return lhs.id.rawValue < rhs.id.rawValue
            }
            return lhs.name < rhs.name
        }
    }

    public var isEmpty: Bool { entries.isEmpty }

    public func capability(for id: CapabilityID) -> CapabilityDescriptor? {
        entries.first { $0.id == id }
    }

    /// Unknown IDs resolve to omitted, which lets callers ask for a capability
    /// state without scattering "is this adapter installed?" checks.
    public func state(for id: CapabilityID) -> CapabilityState {
        capability(for: id)?.state ?? .omitted
    }

    @discardableResult
    public mutating func register(_ capability: CapabilityDescriptor) throws -> Bool {
        guard capability.origin == .optionalCapability else {
            throw CapabilityRegistrationError.coreModule(capability.id)
        }
        guard !entries.contains(where: { $0.id == capability.id }) else {
            throw CapabilityRegistrationError.duplicate(capability.id)
        }
        entries.append(capability)
        return true
    }

    public mutating func register(contentsOf capabilities: [CapabilityDescriptor]) throws {
        var registeredIDs = Set(entries.map(\.id))
        for capability in capabilities {
            guard capability.origin == .optionalCapability else {
                throw CapabilityRegistrationError.coreModule(capability.id)
            }
            guard registeredIDs.insert(capability.id).inserted else {
                throw CapabilityRegistrationError.duplicate(capability.id)
            }
        }
        entries.append(contentsOf: capabilities)
    }
}
