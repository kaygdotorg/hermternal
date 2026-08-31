import SwiftUI
import HermternalCore
import AppKit

struct FindBar: View {
    @Binding var query: String
    let matchCount: Int
    let selectedMatchNumber: Int?
    let isTruncated: Bool
    let focusRequest: Int
    let next: () -> Void
    let previous: () -> Void
    let close: () -> Void

    @Environment(\.hermternalAccentColor) private var accentColor
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
                .frame(minWidth: 72, alignment: .trailing)
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
        .tint(accentColor)
        .background(.thickMaterial, in: .capsule)
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .onAppear {
            // No entrance animation: ⌘F must be ready for the next keystroke.
            fieldFocused = true
        }
        .onChange(of: focusRequest) { _, _ in
            fieldFocused = true
        }
    }

    private var countLabel: String {
        Self.countLabel(
            query: query,
            matchCount: matchCount,
            selectedMatchNumber: selectedMatchNumber,
            isTruncated: isTruncated
        )
    }

    static func countLabel(
        query: String,
        matchCount: Int,
        selectedMatchNumber: Int?,
        isTruncated: Bool
    ) -> String {
        let total = isTruncated ? "\(matchCount)+" : "\(matchCount)"
        guard matchCount > 0, let selectedMatchNumber else {
            return matchCount == 0 && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "0 matches"
                : ""
        }
        return "\(selectedMatchNumber) of \(total)"
    }
}


/// Shared by Find excerpts and the AppKit block renderer.
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
            let accent = AccentColorStore.resolvedColor()
            result[start..<end].foregroundColor = Color(nsColor: accent)
            result[start..<end].backgroundColor = Color(
                nsColor: accent.withAlphaComponent(offset == 0 ? 0.25 : 0.16)
            )
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
