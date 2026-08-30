import HermternalCore
import SwiftUI

/// The attachment row of the composer.
///
/// The row exists only while the draft holds attachments, or while a send is
/// still sending them. The chips sit in one horizontal scroll view: the
/// system anchor centres them while they fit, and the same view scrolls when
/// they do not. Each chip is a system pull-down button, so the platform owns
/// the shape and the selection treatment. A progress bar appears only for the
/// attachment that is going out now, and it counts real file bytes.
struct ComposerAttachmentStrip: View {
    /// Attachments the user can still remove.
    let attachments: [ComposerAttachment]
    /// Attachments that a send took out of the draft. They stay visible while
    /// their bytes go out, and the user cannot remove them.
    let outgoing: [ComposerAttachment]
    let progress: ComposerStagingProgress?
    let isEnabled: Bool
    let onQuickLook: (URL) -> Void
    let onRemove: (UUID) -> Void

    var body: some View {
        // One scroll view holds every width. The system anchor centres the
        // chips while they are narrower than the row, and the same view
        // scrolls when they are wider, so no chip is ever out of reach.
        //
        // A horizontal scroll view accepts the whole proposed height. The
        // fixed vertical size makes it take the height of one chip instead,
        // so the row never grows into the transcript above it.
        ScrollView(.horizontal) {
            chips.padding(.vertical, 1)
        }
        .fixedSize(horizontal: false, vertical: true)
        .scrollIndicators(.hidden)
        .defaultScrollAnchor(.center)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attachments")
    }

    private var chips: some View {
        HStack(spacing: 6) {
            ForEach(attachments) { attachment in
                ComposerHoverReveal { isRevealed in
                    ComposerAttachmentChip(
                        attachment: attachment,
                        progress: nil,
                        isEnabled: isEnabled,
                        isRevealed: isRevealed,
                        onQuickLook: { onQuickLook(attachment.fileURL) },
                        onRemove: { onRemove(attachment.id) }
                    )
                }
            }
            ForEach(outgoing) { attachment in
                ComposerHoverReveal { isRevealed in
                    ComposerAttachmentChip(
                        attachment: attachment,
                        progress: progress?.id == attachment.id ? progress : nil,
                        isEnabled: true,
                        isRevealed: isRevealed,
                        onQuickLook: { onQuickLook(attachment.fileURL) },
                        onRemove: nil
                    )
                }
            }
        }
    }
}

private struct ComposerAttachmentChip: View {
    let attachment: ComposerAttachment
    let progress: ComposerStagingProgress?
    let isEnabled: Bool
    /// True while the pointer is over this chip, from the hover wrapper.
    let isRevealed: Bool
    let onQuickLook: () -> Void
    /// Nil while the attachment goes out, because it left the draft already.
    let onRemove: (() -> Void)?

    var body: some View {
        Menu {
            Button(action: onQuickLook) {
                Label("Quick Look", systemImage: "eye")
            }
            if let onRemove {
                Button(role: .destructive, action: onRemove) {
                    Label("Remove", systemImage: "trash")
                }
            }
        } label: {
            label
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!isEnabled)
        .help(attachment.displayName)
        .accessibilityLabel(attachment.displayName)
        .accessibilityValue(accessibilityValue)
    }

    /// The chip shows its kind icon, and adds the name and the size while the
    /// pointer is over it. Staging progress is work in flight, so it stays
    /// visible whether or not the chip is revealed.
    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: symbolName)
                .font(ComposerIconMetrics.chip)
            if isRevealed {
                // The 160pt ceiling keeps one long file name from taking the
                // row. Truncation, not a fixed size, does the trimming.
                Text(attachment.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 160, alignment: .leading)
                    .transition(.opacity)
            }
            if let progress {
                ProgressView(
                    value: Double(progress.bytesSent),
                    total: Double(max(progress.bytesTotal, 1))
                )
                .progressViewStyle(.linear)
                .frame(width: 44)
            } else if isRevealed {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .transition(.opacity)
            }
        }
        .font(.callout)
    }

    private var symbolName: String {
        switch attachment.kind {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .file: return "doc"
        case .audioRecording: return "waveform"
        }
    }

    private var detail: String {
        if let duration = attachment.duration {
            return duration.formatted(.time(pattern: .minuteSecond))
        }
        return attachment.byteCount.composerByteSize
    }

    private var accessibilityValue: String {
        if let progress {
            let sent = progress.bytesSent.composerByteSize
            let total = progress.bytesTotal.composerByteSize
            return "Sending, \(sent) of \(total)"
        }
        return detail
    }
}
