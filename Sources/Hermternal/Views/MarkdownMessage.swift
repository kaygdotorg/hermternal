import SwiftUI
import HermternalCore


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
        .background(.background.secondary, in: .rect(cornerRadius: 8))
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
