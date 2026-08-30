import Foundation

/// The three speakers exposed by the transcript presentation interface.
public enum TranscriptSpeaker: String, Codable, Hashable, Sendable {
    case me = "Me"
    case hermes = "Hermes"
    case system = "System"
    public var label: String { rawValue }
}

/// A channel is content inside one turn. Channels have no platform geometry.
public enum TranscriptChannelKind: String, Codable, Hashable, Sendable {
    case reasoning
    case tools
    case answer
}

public enum TranscriptToolState: String, Codable, Hashable, Sendable {
    case running
    case completed
    case error
}

/// A model-switch marker retained outside rendered rows.
public struct TranscriptModelSwitchMarker: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let model: String?
    /// Position in the complete wire order.
    public let ordinal: Int
    /// Position in rendered rows, when the marker came from a paged store.
    public let renderedOrdinal: Int?

    public init(id: String, model: String?, ordinal: Int, renderedOrdinal: Int? = nil) {
        self.id = id
        self.model = model
        self.ordinal = ordinal
        self.renderedOrdinal = renderedOrdinal
    }
}
/// Compact metadata for one turn in the full wire order.
public struct TranscriptTurnIndexEntry: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let firstWireOrdinal: Int
    public var lastWireOrdinal: Int
    public let speaker: TranscriptSpeaker

    public init(id: String, firstWireOrdinal: Int, lastWireOrdinal: Int, speaker: TranscriptSpeaker) {
        self.id = id
        self.firstWireOrdinal = firstWireOrdinal
        self.lastWireOrdinal = lastWireOrdinal
        self.speaker = speaker
    }
}
/// Reasoning content and its optional, truthful effort metadata.
public struct TranscriptReasoning: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let text: String
    public let effort: String?

    public init(id: String, text: String, effort: String? = nil) {
        self.id = id
        self.text = text
        self.effort = effort
    }

    public var label: String {
        guard let effort, !effort.isEmpty else { return "Reasoning" }
        return "Reasoning (\(effort))"
    }
}

/// One real tool run. Progress updates replace state without changing its id.
public struct TranscriptToolRun: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let input: String?
    public let output: String?
    public let state: TranscriptToolState

    public init(
        id: String,
        name: String,
        input: String? = nil,
        output: String? = nil,
        state: TranscriptToolState = .running
    ) {
        self.id = id
        self.name = name
        self.input = input
        self.output = output
        self.state = state
    }
}

/// One container-free turn document. Reasoning and tools precede the answer.
public struct TranscriptTurn: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let speaker: TranscriptSpeaker
    public let model: String?
    public let reasoning: TranscriptReasoning?
    public let tools: [TranscriptToolRun]
    public let answer: String
    public let timestamp: Date?

    public init(
        id: String,
        speaker: TranscriptSpeaker,
        model: String? = nil,
        reasoning: TranscriptReasoning? = nil,
        tools: [TranscriptToolRun] = [],
        answer: String = "",
        timestamp: Date? = nil
    ) {
        self.id = id
        self.speaker = speaker
        self.model = model
        self.reasoning = reasoning
        self.tools = tools
        self.answer = answer
        self.timestamp = timestamp
    }

    public var channels: [TranscriptChannelKind] {
        var result: [TranscriptChannelKind] = []
        if reasoning != nil { result.append(.reasoning) }
        if !tools.isEmpty { result.append(.tools) }
        if !answer.isEmpty { result.append(.answer) }
        return result
    }
}

/// A bounded page of turn documents for platform adapters.
public struct TranscriptTurnPage: Codable, Hashable, Sendable {
    public let turns: [TranscriptTurn]
    /// Contiguous turn ordinals, independent of wire row ordinals.
    public let startOrdinal: Int
    public let nextOrdinal: Int
    public let totalTurnCount: Int
    public let hasMore: Bool
    public let modelSwitches: [TranscriptModelSwitchMarker]

    public init(
        turns: [TranscriptTurn],
        startOrdinal: Int,
        nextOrdinal: Int,
        totalTurnCount: Int? = nil,
        hasMore: Bool,
        modelSwitches: [TranscriptModelSwitchMarker] = []
    ) {
        self.turns = turns
        self.startOrdinal = startOrdinal
        self.nextOrdinal = nextOrdinal
        self.totalTurnCount = totalTurnCount ?? nextOrdinal
        self.hasMore = hasMore
        self.modelSwitches = modelSwitches
    }
}

public struct TranscriptTurnPageRequest: Codable, Hashable, Sendable {
    public let startOrdinal: Int
    public let maximumRows: Int
    public let maximumBytes: Int
    public let expectedGeneration: UInt64?
    public let expectedEpoch: UInt64?
    public let sessionModel: String?

    public init(
        startOrdinal: Int = 0,
        maximumRows: Int = 64,
        maximumBytes: Int = 1 * 1024 * 1024,
        expectedGeneration: UInt64? = nil,
        expectedEpoch: UInt64? = nil,
        sessionModel: String? = nil
    ) {
        precondition(startOrdinal >= 0 && maximumRows > 0 && maximumBytes > 0)
        self.startOrdinal = startOrdinal
        self.maximumRows = min(maximumRows, TranscriptPageRequest.hardMaximumRows)
        self.maximumBytes = min(maximumBytes, TranscriptPageRequest.hardMaximumBytes)
        self.expectedGeneration = expectedGeneration
        self.expectedEpoch = expectedEpoch
        self.sessionModel = sessionModel
    }
}

/// The only page operation needed by platform transcript adapters.
public protocol TranscriptTurnPageReading: Sendable {
    func turnPage(_ request: TranscriptTurnPageRequest) async throws -> TranscriptTurnPage
}

/// A contiguous location in the turn document.
public struct TurnLocation: Codable, Hashable, Sendable {
    public let ordinal: Int

    public init(ordinal: Int) {
        precondition(ordinal >= 0)
        self.ordinal = ordinal
    }
}

/// Locates a durable message in projected turn order.
public protocol TranscriptTurnLocating: Sendable {
    func locateTurn(messageID: String) async throws -> TurnLocation?
}

/// The composed interface consumed by transcript adapters.
public protocol TranscriptTurnPageLocating: TranscriptTurnPageReading, TranscriptTurnLocating {}

/// Projects ordered wire records into turns and indexes model markers.
public enum TranscriptTurnProjector {
    public static func modelSwitches(in records: [WireMessageRecord]) -> [TranscriptModelSwitchMarker] {
        records.enumerated().compactMap { ordinal, record in
            guard record.isModelSwitch else { return nil }
            return TranscriptModelSwitchMarker(
                id: record.messageID,
                model: record.modelSwitchName,
                ordinal: ordinal
            )
        }
    }

    public static func project(
        records: [WireMessageRecord],
        sessionModel: String? = nil
    ) -> [TranscriptTurn] {
        project(
            records: records,
            sessionModel: sessionModel,
            hasModelMarkers: nil,
            initialModel: nil
        )
    }

    public static func project(
        records: [WireMessageRecord],
        sessionModel: String?,
        hasModelMarkers: Bool?,
        initialModel: String?
    ) -> [TranscriptTurn] {
        let markers = modelSwitches(in: records)
        let hasMarkers = hasModelMarkers ?? !markers.isEmpty
        var markerCursor = 0
        var activeModel = initialModel
        var turns: [MutableTurn] = []
        var currentTurn = -1

        for (ordinal, record) in records.enumerated() {
            while markerCursor < markers.count && markers[markerCursor].ordinal < ordinal {
                activeModel = markers[markerCursor].model
                markerCursor += 1
            }
            guard !record.isModelSwitch else { continue }

            if record.isToolEvent {
                if currentTurn < 0 || turns[currentTurn].speaker != .hermes {
                    currentTurn = turns.count
                    turns.append(MutableTurn(
                        id: record.turnID ?? record.messageID,
                        speaker: .hermes,
                        model: hasMarkers ? activeModel : sessionModel,
                        timestamp: record.timestamp
                    ))
                }
                turns[currentTurn].addTool(record)
                continue
            }

            let speaker = TranscriptSpeaker(role: record.role)
            let stableID = record.turnID ?? record.messageID
            let startsNewTurn = currentTurn < 0
                || turns[currentTurn].speaker != speaker
                || turns[currentTurn].id != stableID
                || record.turnID == nil
            if startsNewTurn {
                currentTurn = turns.count
                turns.append(MutableTurn(
                    id: stableID,
                    speaker: speaker,
                    model: hasMarkers ? activeModel : sessionModel,
                    timestamp: record.timestamp
                ))
            }
            turns[currentTurn].append(record)
        }
        return turns.map(\.value)
    }

    private struct MutableTurn {
        let id: String
        let speaker: TranscriptSpeaker
        let model: String?
        let timestamp: Date?
        var reasoningText = ""
        var reasoningEffort: String?
        var answer = ""
        var tools: [String: TranscriptToolRun] = [:]
        var toolOrder: [String] = []

        init(id: String, speaker: TranscriptSpeaker, model: String?, timestamp: Date?) {
            self.id = id
            self.speaker = speaker
            self.model = model
            self.timestamp = timestamp
        }

        mutating func append(_ record: WireMessageRecord) {
            if let reasoning = record.reasoning, !reasoning.isEmpty {
                reasoningText += reasoning
                if reasoningEffort == nil { reasoningEffort = record.reasoningEffort }
            }
            answer += record.text
            if reasoningText.isEmpty, let effort = record.reasoningEffort, !effort.isEmpty {
                reasoningEffort = effort
            }
        }

        mutating func addTool(_ record: WireMessageRecord) {
            let toolID = record.toolID
            let previous = tools[toolID]
            let state = record.toolState ?? previous?.state ?? .running
            let run = TranscriptToolRun(
                id: "\(id):tool:\(toolID)",
                name: record.toolName ?? previous?.name ?? "Tool",
                input: record.toolInput ?? previous?.input,
                output: record.toolOutput ?? (record.text.isEmpty ? previous?.output : record.text),
                state: state
            )
            if previous == nil { toolOrder.append(toolID) }
            tools[toolID] = run
        }

        var value: TranscriptTurn {
            TranscriptTurn(
                id: id,
                speaker: speaker,
                model: model,
                reasoning: reasoningText.isEmpty ? nil : TranscriptReasoning(
                    id: "\(id):reasoning",
                    text: reasoningText,
                    effort: reasoningEffort
                ),
                tools: toolOrder.compactMap { tools[$0] },
                answer: answer,
                timestamp: timestamp
            )
        }
    }
}

private extension TranscriptSpeaker {
    init(role: String) {
        switch role.lowercased() {
        case "user", "me": self = .me
        case "assistant", "hermes", "agent": self = .hermes
        default: self = .system
        }
    }
}
