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
    /// Streaming replies and user messages are drawn as one plain run:
    /// streaming would re-segment on every delta, and a user message is not
    /// markdown on the unhighlighted path either, so segmenting it only when
    /// Find is open would make the same text render two different ways.
    let isPlainText: Bool
    let matchRanges: [Range<Int>]
    let isActive: Bool

    var body: some View {
        Group {
            if isPlainText {
                Group {
                    if matchRanges.isEmpty {
                        Text(text)
                    } else {
                        Text(FindTextHighlighting.mark(
                            AttributedString(text),
                            ranges: matchRanges
                        ))
                    }
                }
                .font(.body)
                .foregroundStyle(.primary)
                .lineSpacing(MessageTypography.bodyLineSpacing)
                .textSelection(.enabled)
            } else {
                // Same renderer as the unhighlighted transcript, so type,
                // spacing, and code chrome cannot drift between the two.
                MarkdownBlocks(
                    text: text,
                    matches: MessageFindMatches(text: text, ranges: matchRanges)
                )
            }
        }
        .padding(.vertical, isActive ? 4 : 0)
        // This highlight can contain a code block, so it stays larger than
        // the nested 8pt code shape and smaller than the 14pt message bubble
        // it can sit inside; the curves remain concentric.
        .background(
            isActive ? Color.orange.opacity(0.12) : .clear,
            in: .rect(cornerRadius: AppShapeScale.row, style: .continuous)
        )
        .overlay {
            if isActive {
                RoundedRectangle(cornerRadius: AppShapeScale.row, style: .continuous)
                    .strokeBorder(.orange.opacity(0.8), lineWidth: 1)
            }
        }
    }
}

/// Shared by the transcript's plain and highlighted renderers.
enum FindTextHighlighting {
    static func mark(
        _ source: AttributedString,
        ranges: [Range<Int>]
    ) -> AttributedString {
        guard !ranges.isEmpty else { return source }
        let rendered = String(source.characters)

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

    static func project(
        _ sourceRanges: [Range<Int>],
        from source: String,
        to rendered: String
    ) -> [Range<Int>] {
        guard !sourceRanges.isEmpty, !rendered.isEmpty else { return [] }
        var projected: [Range<Int>] = []
        var searchStart = rendered.startIndex
        var previousSourceStart = -1

        for sourceRange in sourceRanges {
            let lower = source.utf16.index(source.utf16.startIndex, offsetBy: sourceRange.lowerBound)
            let upper = source.utf16.index(source.utf16.startIndex, offsetBy: sourceRange.upperBound)
            let fragment = String(decoding: source.utf16[lower..<upper], as: UTF16.self)
            guard !fragment.isEmpty,
                  let found = rendered.range(
                    of: fragment,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: searchStart..<rendered.endIndex
                  )
            else { continue }

            let lowerOffset = rendered.utf16.distance(
                from: rendered.utf16.startIndex,
                to: found.lowerBound
            )
            let upperOffset = rendered.utf16.distance(
                from: rendered.utf16.startIndex,
                to: found.upperBound
            )
            projected.append(lowerOffset..<upperOffset)
            if sourceRange.lowerBound > previousSourceStart {
                searchStart = found.upperBound
            }
            previousSourceStart = sourceRange.lowerBound
        }
        return projected
    }

    private static func characterOffset(_ utf16Offset: Int, in text: String) -> Int {
        let utf16Index = text.utf16.index(text.utf16.startIndex, offsetBy: utf16Offset)
        let stringIndex = String.Index(utf16Index, within: text) ?? text.endIndex
        return text.distance(from: text.startIndex, to: stringIndex)
    }
}
