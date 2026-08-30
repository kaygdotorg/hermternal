import Foundation

private func nonEmptyString(_ value: JSONValue?) -> String? {
    guard let value, let string = value.stringValue else { return nil }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

public enum ReasoningEffort: String, CaseIterable, Sendable {
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max
    case ultra
}

public enum ReasoningSetting: Equatable, Sendable {
    case off
    case effort(ReasoningEffort)

    public var wireValue: String {
        switch self {
        case .off: return "none"
        case let .effort(value): return value.rawValue
        }
    }
}

public struct SessionRuntimeSnapshot: Equatable, Sendable {
    public let model: String?
    public let provider: String?
    public let reasoning: ReasoningSetting?
    public let isRunning: Bool

    public init(model: String?, provider: String?, reasoning: ReasoningSetting?, isRunning: Bool) {
        self.model = model
        self.provider = provider
        self.reasoning = reasoning
        self.isRunning = isRunning
    }

    public static func decode(_ info: JSONValue?) -> SessionRuntimeSnapshot {
        guard case let .object(raw)? = info else {
            return SessionRuntimeSnapshot(model: nil, provider: nil, reasoning: nil, isRunning: false)
        }
        let values: [String: JSONValue]
        if case let .object(nested)? = raw["info"] { values = nested } else { values = raw }
        let model = clean(values["model"]?.stringValue)
        let provider = clean(values["provider"]?.stringValue)
        let reasoning: ReasoningSetting?
        if let value = values["reasoning_effort"]?.stringValue {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "none" { reasoning = .off }
            else if let effort = ReasoningEffort(rawValue: normalized) { reasoning = .effort(effort) }
            else { reasoning = nil }
        } else { reasoning = nil }
        return SessionRuntimeSnapshot(
            model: model,
            provider: provider,
            reasoning: reasoning,
            isRunning: values["running"]?.boolValue ?? false
        )
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}

public struct ModelCapabilities: Equatable, Sendable {
    public let supportsFast: Bool
    public let supportsReasoning: Bool
    public let canDisableReasoning: Bool?

    public init(supportsFast: Bool, supportsReasoning: Bool, canDisableReasoning: Bool? = nil) {
        self.supportsFast = supportsFast
        self.supportsReasoning = supportsReasoning
        self.canDisableReasoning = canDisableReasoning
    }
}

public struct ModelInventory: Equatable, Sendable {
    public struct Provider: Equatable, Sendable {
        public let slug: String
        public let name: String
        public let isCurrent: Bool
        public let models: [String]
        public let capabilities: [String: ModelCapabilities]

        public init(
            slug: String,
            name: String,
            isCurrent: Bool,
            models: [String],
            capabilities: [String: ModelCapabilities]
        ) {
            self.slug = slug
            self.name = name
            self.isCurrent = isCurrent
            self.models = models
            self.capabilities = capabilities
        }
    }

    public let providers: [Provider]

    public init(providers: [Provider]) { self.providers = providers }

    public static func decode(_ payload: JSONValue) throws -> ModelInventory {
        guard case let .object(root) = payload,
              case let .array(providerValues) = root["providers"] else {
            throw ModelInventoryDecodeError.missingProviders
        }

        var providers: [Provider] = []
        providers.reserveCapacity(providerValues.count)
        for value in providerValues {
            guard case let .object(raw) = value,
                  let slug = nonEmptyString(raw["slug"]),
                  let name = nonEmptyString(raw["name"] ?? .string(slug)),
                  case let .array(modelValues) = raw["models"] else {
                throw ModelInventoryDecodeError.malformedProvider
            }
            var models: [String] = []
            models.reserveCapacity(modelValues.count)
            for model in modelValues {
                guard let modelName = nonEmptyString(model) else {
                    throw ModelInventoryDecodeError.malformedModel(slug: slug)
                }
                models.append(modelName)
            }

            var capabilities: [String: ModelCapabilities] = [:]
            if let capabilityValue = raw["capabilities"] {
                guard case let .object(rawCapabilities) = capabilityValue else {
                    throw ModelInventoryDecodeError.malformedCapabilities(slug: slug)
                }
                for (modelName, capabilityValue) in rawCapabilities {
                    guard case let .object(capability) = capabilityValue,
                          let fast = capability["fast"]?.boolValue,
                          let reasoning = capability["reasoning"]?.boolValue else {
                        throw ModelInventoryDecodeError.malformedCapabilities(slug: slug)
                    }
                    let canDisable = capability["can_disable_reasoning"]?.boolValue
                    capabilities[modelName] = ModelCapabilities(
                        supportsFast: fast,
                        supportsReasoning: reasoning,
                        canDisableReasoning: canDisable
                    )
                }
            }
            providers.append(Provider(
                slug: slug,
                name: name,
                isCurrent: raw["is_current"]?.boolValue ?? false,
                models: models,
                capabilities: capabilities
            ))
        }
        return ModelInventory(providers: providers)
    }
}

public enum ModelInventoryDecodeError: Error, Equatable, Sendable {
    case missingProviders
    case malformedProvider
    case malformedModel(slug: String)
    case malformedCapabilities(slug: String)
}

public struct ModelSwitchOutcome: Equatable, Sendable {
    public let appliedValue: String
    public let isDeferredToNextTurn: Bool

    public init(appliedValue: String, isDeferredToNextTurn: Bool) {
        self.appliedValue = appliedValue
        self.isDeferredToNextTurn = isDeferredToNextTurn
    }
}
