import HermternalCore

/// The narrow seam shared by transcript rendering adapters.
///
/// `blocks` are the stable render units. `messages` are the windowed source
/// messages used to resolve each block's UTF-16 source range and preserve
/// message-level chrome. `window` is resolved by `TranscriptWindowPolicy` in
/// `ChatView`; adapters consume it rather than deriving their own window.
struct TranscriptRendererInput {
    let blocks: [TranscriptBlock]
    let messages: [ChatMessage]
    let window: TranscriptWindow
    let routeIdentity: String
    let isReadOnly: Bool
    let isStreaming: Bool
    let findQuery: String
    let findMatches: [TranscriptMatch]
    let activeFindIndex: Int?
    let pendingMessageID: MessageIdentity?
    let onRequestOlder: () -> Void
    let onCopyCode: (String) -> Void
    let onPaint: (UInt64) -> Void
}

