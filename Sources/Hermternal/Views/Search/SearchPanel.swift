import SwiftUI
import AppKit
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
                SearchPanelBackdrop()
                    .opacity(hasAppeared ? 1 : 0)
                    .ignoresSafeArea()

                // Keep dismissal available without putting an invisible view in
                // the accessibility or keyboard focus order.
                Rectangle()
                    .fill(.clear)
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
            }
            .animation(panelAnimation, value: hasAppeared)
            .onAppear {
                // Focus is established before the visual ramp so ⌘K is
                // immediately ready for typing, including Reduce Motion.
                fieldFocused = true
                hasAppeared = true
            }
            .onExitCommand(perform: dismiss)
        }
    }

    private var panelAnimation: Animation {
        Self.panelAnimation(reduceMotion: reduceMotion)
    }

    static func panelAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeOut(duration: 0.18)
            : .spring(response: 0.36, dampingFraction: 1)
    }

}

private struct SearchPanelBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .fullScreenUI
        view.blendingMode = .withinWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = .fullScreenUI
        view.blendingMode = .withinWindow
        view.state = .active
        view.isEmphasized = true
    }
}

private struct SearchPanelField: View {
    @Bindable var model: SearchPanelModel
    let fieldFocused: FocusState<Bool>.Binding
    let activateSelection: () -> Void
    let dismiss: () -> Void

    private var metadata: SearchFieldMetadata? {
        guard case .results(let results) = model.state else { return nil }
        return SearchFieldMetadata(
            count: results.hits.count,
            pendingIndexingSessions: results.pendingIndexingSessions,
            truncatedSessions: results.truncatedSessions
        )
    }

    private var metadataReservation: CGFloat {
        guard let metadata else { return 0 }
        let countWidth = metadata.count < 100
            ? 24
            : max(24, CGFloat(String(metadata.count).count * 8 + 10))
        let statusWidth: CGFloat = (metadata.pendingIndexingSessions > 0 ? 28 : 0)
            + (metadata.truncatedSessions > 0 ? 28 : 0)
        return countWidth + statusWidth + 10
    }

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)

                ZStack(alignment: .trailing) {
                    TextField("Search all messages", text: $model.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17, weight: .regular, design: .rounded))
                        .focused(fieldFocused)
                        .submitLabel(.search)
                        .onSubmit(activateSelection)
                        .padding(.trailing, metadataReservation)
                        .mask {
                            if metadata != nil {
                                LinearGradient(
                                    stops: [
                                        .init(color: .black, location: 0),
                                        .init(color: .black, location: 0.78),
                                        .init(color: .black.opacity(0.72), location: 0.9),
                                        .init(color: .clear, location: 1)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            } else {
                                Rectangle().fill(.black)
                            }
                        }
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

                    if let metadata {
                        SearchFieldMetadataView(metadata: metadata)
                            .padding(.trailing, 2)
                    }
                }
                .frame(maxWidth: .infinity)

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
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .glassEffect(.clear.interactive(), in: .capsule)
        }
    }
}

private struct SearchFieldMetadata: Sendable {
    let count: Int
    let pendingIndexingSessions: Int
    let truncatedSessions: Int
}

private struct SearchFieldMetadataView: View {
    let metadata: SearchFieldMetadata

    private var countLabel: String {
        "\(metadata.count) \(metadata.count == 1 ? "message" : "messages")"
    }

    private var indexingLabel: String {
        "Older messages in \(metadata.pendingIndexingSessions) chats are still being indexed"
    }

    private var truncationLabel: String {
        "Older messages in \(metadata.truncatedSessions) chats are not searchable because the server caps history at 500 messages per chat"
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("\(metadata.count)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .frame(minWidth: 24, minHeight: 24)
                .padding(.horizontal, metadata.count < 100 ? 0 : 5)
                .background(.quaternary, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                }
                .help(countLabel)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(countLabel)

            if metadata.pendingIndexingSessions > 0 {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 22, height: 22)
                    .help(indexingLabel)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(indexingLabel)
            }

            if metadata.truncatedSessions > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .help(truncationLabel)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(truncationLabel)
            }
        }
    }
}

private struct SearchFieldHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 46

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct SearchFieldFrameKey: PreferenceKey {
    static let defaultValue = CGRect.zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private struct SearchPanelSurface: View {
    @Bindable var model: SearchPanelModel
    let fieldFocused: FocusState<Bool>.Binding
    let maximumHeight: CGFloat
    let activate: (MessageLocation) -> Void
    let dismiss: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast
    @State private var fieldHeight: CGFloat = SearchFieldHeightKey.defaultValue
    @State private var fieldFrame: CGRect = .zero

    private let fieldMargin: CGFloat = 15

    private var fieldContentInset: CGFloat {
        fieldHeight + fieldMargin * 2
    }


    var body: some View {
        ZStack(alignment: .top) {
            content
                .frame(maxWidth: .infinity, alignment: .topLeading)

            SearchPanelField(
                model: model,
                fieldFocused: fieldFocused,
                activateSelection: activateSelection,
                dismiss: dismiss
            )
            .frame(maxWidth: .infinity)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: SearchFieldHeightKey.self,
                        value: geometry.size.height
                    )
                }
            }
            // Measure the glass pill itself before the surrounding padding.
            // The mask uses this frame to stop concealing exactly at the
            // pill's top edge, leaving its entire refractive area visible.
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: SearchFieldFrameKey.self,
                        value: geometry.frame(in: .named("searchPanelSurface"))
                    )
                }
            }
            .zIndex(1)
            .padding(.horizontal, 18)
            .padding(.vertical, fieldMargin)
        }
        .coordinateSpace(name: "searchPanelSurface")
        .frame(maxHeight: maximumHeight, alignment: .top)
        // The window frost beneath the panel carries the visual weight. A
        // thin pane keeps the app recognizable through the card instead of
        // stacking an opaque material over the backdrop.
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    contrast == .increased ? Color.primary : Color.primary.opacity(0.18),
                    lineWidth: contrast == .increased ? 1.5 : 0.75
                )
        }
        .shadow(color: .black.opacity(0.28), radius: 28, y: 14)
        .onPreferenceChange(SearchFieldHeightKey.self) { height in
            fieldHeight = height
        }
        .onPreferenceChange(SearchFieldFrameKey.self) { frame in
            fieldFrame = frame
        }
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
                .padding(.top, fieldContentInset)
        case .loading:
            LoadingSearchState()
                .padding(.top, fieldContentInset)
        case .results(let results):
            ResultsSearchState(
                results: results,
                selectedIndex: model.selectedIndex,
                topInset: fieldContentInset,
                fieldFrame: fieldFrame,
                activate: activate
            )
            .frame(height: maximumHeight)
        case .noResults(let query):
            NoResultsSearchState(query: query)
                .padding(.top, fieldContentInset)
        case .error(_, let message):
            ErrorSearchState(message: message, retry: model.retry)
                .padding(.top, fieldContentInset)
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
    let topInset: CGFloat
    let fieldFrame: CGRect
    let activate: (MessageLocation) -> Void

    // Only the content above the measured glass top is concealed. Once rows
    // reach the top edge, they remain present for the clear glass to refract.
    private static let aboveFieldFadeDistance: CGFloat = 24
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
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
            // The list owns its 12pt row inset; the pill owns only the
            // top content inset, so neither creates a surrounding band.
            .padding(.horizontal, 12)
            // This is scroll content inset, not a second field-sized region.
            // Rows remain in the scroll view and can travel behind the pill.
            .padding(.top, topInset)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .mask {
            GeometryReader { geometry in
                let viewportHeight = max(geometry.size.height, 1)
                let measuredFieldTop = fieldFrame.height > 0
                    ? fieldFrame.minY
                    : 0
                let fieldTopEdge = min(
                    max(measuredFieldTop, 0),
                    viewportHeight
                )
                let aboveFieldFadeStart = max(
                    fieldTopEdge - Self.aboveFieldFadeDistance,
                    0
                )
                // A mask reveals content where it is opaque. The only
                // transparent region is above the measured field top edge;
                // from that edge down, rows stay visible behind the glass
                // and fully legible below it. There is deliberately no
                // bottom ramp: the pill edge already transitions the rows.
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: aboveFieldFadeStart / viewportHeight),
                        .init(color: .black, location: fieldTopEdge / viewportHeight),
                        .init(color: .black, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
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

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button(action: activate) {
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
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                isSelected
                    ? Color.accentColor.opacity(contrast == .increased ? 0.24 : 0.12)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                if isSelected && contrast == .increased {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
