import Foundation

/// Strips in-flight presentation from a disk transcript.
///
/// A launch paints a static snapshot. Spinners and empty streaming rows are
/// launch-time presentation, not durable history.
public enum CachedTranscriptScrubbing {
    public static func scrub(_ messages: [ChatMessage]) -> [ChatMessage] {
        var result: [ChatMessage] = []
        result.reserveCapacity(messages.count)
        for message in messages {
            if message.isStreaming, message.text.isEmpty {
                continue
            }
            var copy = message
            copy.isStreaming = false
            result.append(copy)
        }
        return result
    }

    public static func needsScrub(_ messages: [ChatMessage]) -> Bool {
        messages.contains { message in
            message.isStreaming
        }
    }
}
