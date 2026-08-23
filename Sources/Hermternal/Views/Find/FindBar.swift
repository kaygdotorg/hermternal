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
    let matchRanges: [Range<Int>]
    let isActive: Bool

    var body: some View {
        Group {
            if isStreaming {
                Text(FindTextHighlighting.mark(
                    AttributedString(text),
                    ranges: matchRanges
                ))
                .textSelection(.enabled)
            } else {
                let segments = MarkdownSegment.parse(text)
                let sourceSegments = FindTextHighlighting.sourceSegments(for: text)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                        let source = sourceSegments.indices.contains(index)
                            ? sourceSegments[index]
                            : .init(sourceRange: 0..<text.utf16.count)
                        switch segment {
                        case .prose(_, let attributed):
                            Text(FindTextHighlighting.mark(
                                attributed,
                                ranges: FindTextHighlighting.project(
                                    matchRanges.filter { source.sourceRange.contains($0.lowerBound) },
                                    from: text,
                                    to: String(attributed.characters)
                                )
                            ))
                            .textSelection(.enabled)
                        case .code(_, let language, let body):
                            FindHighlightedCodeBlock(
                                language: language,
                                code: body,
                                languageRanges: FindTextHighlighting.project(
                                    matchRanges.filter {
                                        source.languageRange?.contains($0.lowerBound) == true
                                    },
                                    from: text,
                                    to: language
                                ),
                                codeRanges: FindTextHighlighting.project(
                                    matchRanges.filter { source.sourceRange.contains($0.lowerBound) },
                                    from: text,
                                    to: body
                                )
                            )
                        }
                    }
                }
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

private struct FindHighlightedCodeBlock: View {
    let language: String
    let code: String
    let languageRanges: [Range<Int>]
    let codeRanges: [Range<Int>]
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(
                    FindTextHighlighting.mark(
                        AttributedString(language.isEmpty ? "code" : language),
                        ranges: languageRanges
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
                Text(FindTextHighlighting.mark(
                    AttributedString(code),
                    ranges: codeRanges
                ))
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
            }
        }
        .background(
            .background.secondary,
            in: .rect(cornerRadius: AppShapeScale.compact, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppShapeScale.compact, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
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
    struct SourceSegment {
        let sourceRange: Range<Int>
        let languageRange: Range<Int>?

        init(sourceRange: Range<Int>, languageRange: Range<Int>? = nil) {
            self.sourceRange = sourceRange
            self.languageRange = languageRange
        }
    }

    static func mark(
        _ source: AttributedString,
        ranges: [Range<Int>]
    ) -> AttributedString {
        let rendered = String(source.characters)
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

    static func sourceSegments(for text: String) -> [SourceSegment] {
        var result: [SourceSegment] = []
        var offset = 0
        var inFence = false
        var proseStart: Int?
        var proseHasContent = false
        var codeStart = 0
        var languageRange: Range<Int>?

        func flushProse(at end: Int) {
            guard let start = proseStart, proseHasContent, start < end else {
                proseStart = nil
                proseHasContent = false
                return
            }
            result.append(SourceSegment(sourceRange: start..<end, languageRange: nil))
            proseStart = nil
            proseHasContent = false
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineStart = offset
            let lineEnd = lineStart + line.utf16.count
            if line.hasPrefix("```") {
                if inFence {
                    result.append(SourceSegment(
                        sourceRange: min(codeStart, lineStart)..<lineStart,
                        languageRange: languageRange
                    ))
                    inFence = false
                    languageRange = nil
                } else {
                    flushProse(at: lineStart)
                    inFence = true
                    codeStart = min(lineEnd + 1, text.utf16.count)
                    languageRange = (lineStart + 3)..<lineEnd
                }
            } else if inFence {
                // The body range starts after the opening fence and extends
                // through the closing fence (or the end for an open fence).
                codeStart = min(codeStart, lineStart)
            } else {
                proseStart = proseStart ?? lineStart
                proseHasContent = proseHasContent
                    || line.contains(where: { !$0.isWhitespace })
            }
            offset = lineEnd + 1
        }

        let end = text.utf16.count
        if inFence {
            result.append(SourceSegment(
                sourceRange: min(codeStart, end)..<end,
                languageRange: languageRange
            ))
        } else {
            flushProse(at: end)
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
