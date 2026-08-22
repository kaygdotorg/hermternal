#if DEBUG
import SwiftUI
import HermternalCore

private struct SearchPanelPreviewQuerying: SearchQuerying {
    func search(_ query: String, limit: Int) async throws -> SearchResults {
        SearchPanelPreviewData.results(query: query, count: 4)
    }
}
private enum SearchPanelPreviewData {
    static let provider = SearchPanelPreviewQuerying()

    static func results(query: String = "launch", count: Int = 4) -> SearchResults {
        let hits = (0..<count).map { index in
            SearchHit(
                location: MessageLocation(
                    sessionID: "preview-session-\(index)",
                    messageID: ServerMessageID(rawValue: Int64(index + 1))
                ),
                sessionTitle: index.isMultiple(of: 2) ? "Release planning" : "Personal notes",
                excerpt: highlightedExcerpt(query: query, index: index),
                role: index.isMultiple(of: 2) ? .assistant : .user,
                timestamp: Date().addingTimeInterval(TimeInterval(-index * 3_600))
            )
        }
        return SearchResults(hits: hits, incompleteSessions: 2)
    }

    static func highlightedExcerpt(query: String, index: Int) -> AttributedString {
        var excerpt = AttributedString(
            "A matching \(query) excerpt keeps the surrounding message context visible for result \(index + 1)."
        )
        if let range = excerpt.range(of: query) {
            excerpt[range].inlinePresentationIntent = .stronglyEmphasized
        }
        return excerpt
    }

    @MainActor
    static func model(
        query: String,
        state: SearchPanelState
    ) -> SearchPanelModel {
        SearchPanelModel(
            querying: provider,
            initialQuery: query,
            initialState: state
        )
    }
}

#Preview("Search — empty") {
    SearchPanel(
        model: SearchPanelPreviewData.model(query: "", state: .empty),
        activate: { _ in },
        dismiss: {}
    )
    .frame(width: 900, height: 700)
}

#Preview("Search — loading") {
    SearchPanel(
        model: SearchPanelPreviewData.model(query: "launch", state: .loading(query: "launch")),
        activate: { _ in },
        dismiss: {}
    )
    .frame(width: 900, height: 700)
}

#Preview("Search — results and corpus warning") {
    SearchPanel(
        model: SearchPanelPreviewData.model(
            query: "launch",
            state: .results(SearchPanelPreviewData.results())
        ),
        activate: { _ in },
        dismiss: {}
    )
    .frame(width: 900, height: 700)
}

#Preview("Search — no results") {
    SearchPanel(
        model: SearchPanelPreviewData.model(
            query: "quasar",
            state: .noResults(query: "quasar")
        ),
        activate: { _ in },
        dismiss: {}
    )
    .frame(width: 900, height: 700)
}

#Preview("Search — error") {
    SearchPanel(
        model: SearchPanelPreviewData.model(
            query: "launch",
            state: .error(query: "launch", message: "The local search index is unavailable.")
        ),
        activate: { _ in },
        dismiss: {}
    )
    .frame(width: 900, height: 700)
}

#Preview("Search — overflow and scroll") {
    SearchPanel(
        model: SearchPanelPreviewData.model(
            query: "launch",
            state: .results(SearchPanelPreviewData.results(count: 18))
        ),
        activate: { _ in },
        dismiss: {}
    )
    .frame(width: 900, height: 700)
}
#endif
