import SwiftUI
import HermternalCore

/// Focused command-K message search surface.
///
/// Integration owns presentation and routing. The panel only queries the
/// injected index and reports the durable location selected by the user.
struct SearchPanel: View {
    @State private var model: SearchPanelModel
    @FocusState private var fieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hasAppeared = false

    private let activate: (MessageLocation) -> Void
    private let dismiss: () -> Void

    init(
        querying: any SearchQuerying,
        activate: @escaping (MessageLocation) -> Void,
        dismiss: @escaping () -> Void
    ) {
        _model = State(initialValue: SearchPanelModel(querying: querying))
        self.activate = activate
        self.dismiss = dismiss
    }
    
    init(
        model: SearchPanelModel,
        activate: @escaping (MessageLocation) -> Void,
        dismiss: @escaping () -> Void
    ) {
        _model = State(initialValue: model)
        self.activate = activate
        self.dismiss = dismiss
    }


    var body: some View {
        GeometryReader { geometry in
            let panelWidth = min(680, max(280, geometry.size.width - 48))
            let maximumHeight = geometry.size.height / 3

            ZStack(alignment: .top) {
                Rectangle()
                    .fill(.black.opacity(contrast == .increased ? 0.76 : 0.62))
                    .background(.ultraThickMaterial)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismiss)
                    .accessibilityHidden(true)

                SearchPanelSurface(
                    model: model,
                    fieldFocused: $fieldFocused,
                    maximumHeight: maximumHeight,
                    activate: activate,
                    dismiss: dismiss
                )
                .frame(width: panelWidth)
                .padding(.top, geometry.size.height / 3)
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(reduceMotion ? 1 : (hasAppeared ? 1 : 0.985), anchor: .top)
                .offset(y: reduceMotion ? 0 : (hasAppeared ? 0 : -10))
            .animation(
                reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.36, dampingFraction: 1),
                value: hasAppeared
            )
            .onAppear {
                fieldFocused = true
                hasAppeared = true
            }
            .onExitCommand(perform: dismiss)
        }
    }
}

}
private struct SearchPanelField: View {
    @Bindable var model: SearchPanelModel
    let fieldFocused: FocusState<Bool>.Binding
    let activateSelection: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("Search all messages", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .regular, design: .rounded))
                .focused(fieldFocused)
                .submitLabel(.search)
                .onSubmit(activateSelection)
                .accessibilityLabel("Search all messages")
                .accessibilityHint("Type to search the full message text across every chat")
                .onKeyPress(.downArrow) {
                    model.moveSelection(.down)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    model.moveSelection(.up)
                    return .handled
                }
                .onKeyPress(.escape) {
                    dismiss()
                    return .handled
                }

            if !model.query.isEmpty {
                Button {
                    model.query = ""
                    fieldFocused.wrappedValue = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }

            Button(action: dismiss) {
                Image(systemName: "escape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Dismiss search")
        }
    }
}

private struct SearchPanelSurface: View {
    @Bindable var model: SearchPanelModel
    let fieldFocused: FocusState<Bool>.Binding
    let maximumHeight: CGFloat
    let activate: (MessageLocation) -> Void
    let dismiss: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        VStack(spacing: 0) {
            SearchPanelField(
                model: model,
                fieldFocused: fieldFocused,
                activateSelection: activateSelection,
                dismiss: dismiss
            )
            .padding(.horizontal, 18)
            .padding(.vertical, 15)

            Divider()
                .opacity(contrast == .increased ? 1 : 0.65)

            content
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: maximumHeight, alignment: .top)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    contrast == .increased ? Color.primary : Color.primary.opacity(0.18),
                    lineWidth: contrast == .increased ? 1.5 : 0.75
                )
        }
        .shadow(color: .black.opacity(0.28), radius: 28, y: 14)
        .onChange(of: model.query) { _, newQuery in
            model.updateQuery(newQuery)
        }
        .onMoveCommand { direction in
            switch direction {
            case .up:
                model.moveSelection(.up)
            case .down:
                model.moveSelection(.down)
            default:
                break
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(model.selectionAnnouncement ?? "Search field")
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .empty:
            EmptySearchState()
        case .loading:
            LoadingSearchState()
        case .results(let results):
            ResultsSearchState(
                results: results,
                selectedIndex: model.selectedIndex,
                activate: activate
            )
            .frame(maxHeight: max(80, maximumHeight - 70))
        case .noResults(let query):
            NoResultsSearchState(query: query)
        case .error(_, let message):
            ErrorSearchState(message: message, retry: model.retry)
        }
    }

    private func activateSelection() {
        guard let location = model.selectedLocation() else { return }
        activate(location)
    }
}

private struct EmptySearchState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Search every message")
                .font(.headline)
            Text("Find words and phrases across all of your chats.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Label("Use ↑ and ↓ to choose a result, then press Return", systemImage: "arrow.up.arrow.down")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct LoadingSearchState: View {
    var body: some View {
        HStack(spacing: 11) {
            ProgressView()
                .controlSize(.small)
            Text("Searching messages…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Searching messages")
    }
}

private struct ResultsSearchState: View {
    let results: SearchResults
    let selectedIndex: Int?
    let activate: (MessageLocation) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("\(results.hits.count) \(results.hits.count == 1 ? "match" : "matches")")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if results.incompleteSessions > 0 {
                        Label(
                            "Some chats still indexing",
                            systemImage: "clock.arrow.circlepath"
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(
                            "Older messages in \(results.incompleteSessions) chats are not searchable yet"
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 11)
                .padding(.bottom, 5)

                if results.incompleteSessions > 0 {
                    Text("Older messages in some chats are not searchable yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                        .accessibilityLabel(
                            "Older messages in some chats are not searchable yet"
                        )
                }

                ForEach(Array(results.hits.enumerated()), id: \.element.location) { index, hit in
                    SearchResultRow(
                        hit: hit,
                        index: index,
                        resultCount: results.hits.count,
                        isSelected: selectedIndex == index,
                        activate: { activate(hit.location) }
                    )
                }
            }
            .padding(.bottom, 8)
        }
        .scrollIndicators(.visible)
        .accessibilityElement(children: .contain)
        .accessibilityValue(
            selectedIndex.map { "Selected result \($0 + 1) of \(results.hits.count)" } ?? "No result selected"
        )
    }
}

private struct SearchResultRow: View {
    let hit: SearchHit
    let index: Int
    let resultCount: Int
    let isSelected: Bool
    let activate: () -> Void

    var body: some View {
        Button(action: activate) {
            HStack(alignment: .top, spacing: 11) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.28))
                    .frame(width: 3)
                    .padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 6) {
                    Text(hit.excerpt)
                        .font(.body)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    metadata
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .accessibilityLabel(Text("\(hit.sessionTitle.isEmpty ? "Untitled chat" : hit.sessionTitle), \(hit.role.displayName)"))
        .accessibilityValue(Text("Result \(index + 1) of \(resultCount). \(String(hit.excerpt.characters))"))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
    @ViewBuilder
    private var metadata: some View {
        let title = hit.sessionTitle.isEmpty ? "Untitled chat" : hit.sessionTitle
        Group {
            if let timestamp = hit.timestamp {
                Text("\(title) • \(hit.role.displayName) • \(timestamp, style: .relative)")
            } else {
                Text("\(title) • \(hit.role.displayName) • Date unavailable")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct NoResultsSearchState: View {
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("No messages found", systemImage: "text.magnifyingglass")
                .font(.headline)
            Text("No results for “\(query)”")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

}

private struct ErrorSearchState: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Search unavailable", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button("Try Again", action: retry)
                .buttonStyle(.bordered)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

private extension Role {
    var displayName: String {
        rawValue.capitalized
    }
}
