import SwiftUI

/// A message body split into prose and fenced-code runs.
///
/// `AttributedString(markdown:)` handles inline emphasis and code spans but
/// renders a fenced block as ordinary inline text, so fences are split out
/// here and drawn as real blocks. That is the single highest-value piece of
/// formatting in an agent client.
enum MarkdownSegment: Identifiable {
    case prose(id: Int, AttributedString)
    case code(id: Int, language: String, body: String)

    var id: Int {
        switch self {
        case .prose(let id, _): id
        case .code(let id, _, _): id
        }
    }

    static func parse(_ text: String) -> [MarkdownSegment] {
        var segments: [MarkdownSegment] = []
        var proseBuffer: [Substring] = []
        var codeBuffer: [Substring] = []
        var language = ""
        var inFence = false
        var nextID = 0

        func flushProse() {
            let joined = proseBuffer.joined(separator: "\n")
            proseBuffer.removeAll()
            let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            segments.append(.prose(id: nextID, attributed(from: trimmed)))
            nextID += 1
        }

        func flushCode() {
            let body = codeBuffer.joined(separator: "\n")
            codeBuffer.removeAll()
            segments.append(.code(id: nextID, language: language, body: body))
            nextID += 1
            language = ""
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") {
                if inFence {
                    flushCode()
                    inFence = false
                } else {
                    flushProse()
                    language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inFence = true
                }
                continue
            }
            if inFence { codeBuffer.append(line) } else { proseBuffer.append(line) }
        }
        // An unterminated fence is normal mid-stream; render what arrived.
        if inFence { flushCode() } else { flushProse() }
        return segments
    }

    private static func attributed(from markdown: String) -> AttributedString {
        // `.full` keeps hard line breaks, which chat prose relies on.
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: markdown, options: options))
            ?? AttributedString(markdown)
    }
}

struct MarkdownMessage: View {
    let text: String
    /// While deltas land, skip markdown parsing entirely — it would re-parse
    /// the whole message on every token.
    let isStreaming: Bool

    var body: some View {
        if isStreaming {
            Text(text)
                .textSelection(.enabled)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(MarkdownSegment.parse(text)) { segment in
                    switch segment {
                    case .prose(_, let attributed):
                        Text(attributed)
                            .textSelection(.enabled)
                    case .code(_, let language, let source):
                        CodeBlock(language: language, code: source)
                    }
                }
            }
        }
    }
}

private struct CodeBlock: View {
    let language: String
    let code: String
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
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
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
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
