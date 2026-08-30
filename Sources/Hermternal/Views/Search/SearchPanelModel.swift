import Foundation
import HermternalCore
import Observation

/// The complete set of states rendered by `SearchPanel`.
enum SearchPanelState: Sendable {
    case empty
    case loading(query: String)
    case results(SearchResults)
    case noResults(query: String)
    case error(query: String, message: String)
}

/// Main-actor state for the command-K search surface.
///
/// Every request carries a generation and the query that created it. A
/// provider is allowed to ignore cancellation; a completion can still update
/// the panel only when both values are current.
@MainActor
@Observable
final class SearchPanelModel {
    let querying: any SearchQuerying
    let resultLimit: Int

    var query: String
    var state: SearchPanelState
    var selectedIndex: Int?

    private var requestTask: Task<Void, Never>?
    private var generation = 0

    init(
        querying: any SearchQuerying,
        initialQuery: String = "",
        initialState: SearchPanelState? = nil,
        resultLimit: Int = 100
    ) {
        self.querying = querying
        self.resultLimit = min(max(resultLimit, 0), SearchIndex.defaultLimit)
        self.query = initialQuery
        self.state = initialState ?? (initialQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .empty : .loading(query: initialQuery))
        self.selectedIndex = nil
    }

    func updateQuery(_ newValue: String) {
        query = newValue
        generation &+= 1
        requestTask?.cancel()
        requestTask = nil
        selectedIndex = nil

        let normalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            state = .empty
            return
        }

        let requestGeneration = generation
        let requestLimit = resultLimit
        let provider = querying
        state = .loading(query: normalized)

        requestTask = Task { [weak self] in
            do {
                let results = try await provider.search(normalized, limit: requestLimit)
                guard !Task.isCancelled else { return }
                self?.apply(results, for: normalized, generation: requestGeneration)
            } catch is CancellationError {
                // Cancellation is expected when a newer query supersedes this one.
            } catch {
                guard !Task.isCancelled else { return }
                self?.apply(error: error, for: normalized, generation: requestGeneration)
            }
        }
    }

    func retry() {
        updateQuery(query)
    }

    func moveSelection(_ direction: MoveDirection) {
        guard case .results(let results) = state, !results.hits.isEmpty else { return }
        let count = results.hits.count
        let current = selectedIndex ?? (direction == .down ? -1 : 0)
        selectedIndex = switch direction {
        case .down: (current + 1) % count
        case .up: (current - 1 + count) % count
        }
    }

    func selectedLocation() -> MessageLocation? {
        guard case .results(let results) = state,
              let selectedIndex,
              results.hits.indices.contains(selectedIndex) else { return nil }
        return results.hits[selectedIndex].location
    }

    var selectionAnnouncement: String? {
        guard case .results(let results) = state,
              let selectedIndex,
              results.hits.indices.contains(selectedIndex) else { return nil }
        let hit = results.hits[selectedIndex]
        return "Selected result \(selectedIndex + 1) of \(results.hits.count), \(hit.sessionTitle)"
    }

    private func apply(_ results: SearchResults, for query: String, generation: Int) {
        guard self.generation == generation,
              self.query.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
        if results.hits.isEmpty {
            state = .noResults(query: query)
            selectedIndex = nil
        } else {
            state = .results(results)
            selectedIndex = 0
        }
        requestTask = nil
    }

    private func apply(error: Error, for query: String, generation: Int) {
        guard self.generation == generation,
              self.query.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
        state = .error(query: query, message: error.localizedDescription)
        selectedIndex = nil
        requestTask = nil
    }
}

enum MoveDirection: Sendable {
    case up
    case down
}
