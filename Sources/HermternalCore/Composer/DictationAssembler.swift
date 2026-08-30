import Foundation

/// Reduces SpeechTranscriber updates into one insertion in a draft. Volatile
/// recognition replaces only the current tail; final recognition commits that
/// tail before the next utterance begins.
public struct DictationAssembler: Sendable {
    private let prefix: String
    private let suffix: String
    private var committedText = ""
    private var volatileText = ""

    public init(base: String, insertionOffset: Int) {
        let clamped = max(0, min(insertionOffset, base.count))
        let split = base.index(base.startIndex, offsetBy: clamped)
        prefix = String(base[..<split])
        suffix = String(base[split...])
    }

    public mutating func apply(_ update: DictationUpdate) -> String {
        if update.isFinal {
            committedText += update.text
            volatileText.removeAll(keepingCapacity: true)
        } else {
            volatileText = update.text
        }
        return rendered()
    }

    public mutating func finish() -> String {
        committedText += volatileText
        volatileText.removeAll(keepingCapacity: true)
        return rendered()
    }

    private func rendered() -> String {
        prefix + committedText + volatileText + suffix
    }
}
