import SwiftUI
import HermternalCore
import AppKit

struct FindBar: View {
    @Binding var query: String
    let matchCount: Int
    let selectedMatchNumber: Int?
    let next: () -> Void
    let previous: () -> Void
    let close: () -> Void

    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Find in conversation", text: $query)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .submitLabel(.search)
                .onKeyPress(phases: .down) { keyPress in
                    guard keyPress.key == .return else { return .ignored }
                    if keyPress.modifiers.contains(.shift) {
                        previous()
                    } else {
                        next()
                    }
                    return .handled
                }
                .onKeyPress(.escape) {
                    close()
                    return .handled
                }
                .accessibilityLabel("Find in conversation")
                .accessibilityHint("Searches only the current conversation")

            Text(countLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 58, alignment: .trailing)
                .accessibilityLabel(countLabel)

            Button(action: previous) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .disabled(matchCount == 0)
            .help("Previous match")
            .accessibilityLabel("Previous match")

            Button(action: next) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .disabled(matchCount == 0)
            .help("Next match")
            .accessibilityLabel("Next match")

            Button(action: close) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Close find")
            .accessibilityLabel("Close find")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thickMaterial, in: .capsule)
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .onAppear {
            // No entrance animation: ⌘F must be ready for the next keystroke.
            fieldFocused = true
        }
    }

    private var countLabel: String {
        guard matchCount > 0, let selectedMatchNumber else {
            return matchCount == 0 && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "0 matches"
                : ""
        }
        return "\(selectedMatchNumber) of \(matchCount)"
    }
}

struct FindHighlightedMessage: View {
    let text: String
    let isStreaming: Bool
    let query: String
    let isActive: Bool

    var body: some View {
        Group {
            if isStreaming {
                Text(FindTextHighlighting.mark(AttributedString(text), query: query))
                    .textSelection(.enabled)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(MarkdownSegment.parse(text)) { segment in
                        switch segment {
                        case .prose(_, let attributed):
                            Text(FindTextHighlighting.mark(attributed, query: query))
                                .textSelection(.enabled)
                        case .code(_, let language, let body):
                            FindHighlightedCodeBlock(
                                language: language,
                                code: body,
                                query: query
                            )
                        }
                    }
                }
            }
        }
        .padding(.vertical, isActive ? 4 : 0)
        .background(isActive ? Color.orange.opacity(0.12) : .clear, in: .rect(cornerRadius: 8))
        .overlay {
            if isActive {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.orange.opacity(0.8), lineWidth: 1)
            }
        }
    }
}

private struct FindHighlightedCodeBlock: View {
    let language: String
    let code: String
    let query: String
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(
                    FindTextHighlighting.mark(
                        AttributedString(language.isEmpty ? "code" : language),
                        query: query
                    )
                )
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                Spacer()
                Button {
                    copy()
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Copy")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider().opacity(0.5)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(FindTextHighlighting.mark(AttributedString(code), query: query))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(.background.secondary, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            didCopy = false
        }
    }
}

private enum FindTextHighlighting {
    static func mark(_ source: AttributedString, query: String) -> AttributedString {
        let rendered = String(source.characters)
        let ranges = TranscriptMatcher.ranges(in: rendered, query: query)
        guard !ranges.isEmpty else { return source }

        var result = source
        for (offset, range) in ranges.enumerated() {
            let start = result.index(
                result.startIndex,
                offsetByCharacters: characterOffset(range.lowerBound, in: rendered)
            )
            let end = result.index(
                result.startIndex,
                offsetByCharacters: characterOffset(range.upperBound, in: rendered)
            )
            result[start..<end].inlinePresentationIntent = .stronglyEmphasized
            result[start..<end].foregroundColor = offset == 0 ? .orange : .yellow
        }
        return result
    }

    private static func characterOffset(_ utf16Offset: Int, in text: String) -> Int {
        let utf16Index = text.utf16.index(text.utf16.startIndex, offsetBy: utf16Offset)
        let stringIndex = String.Index(utf16Index, within: text) ?? text.endIndex
        return text.distance(from: text.startIndex, to: stringIndex)
    }
}
