import HermternalCore
import SwiftUI

/// Formatting controls shown after the user opens the focused editor's Format
/// disclosure control.
///
/// The row uses regular native targets and larger symbols for reliable input.
struct ComposerFormattingRow: View {
    let mode: ComposerEditorMode
    let onFormat: (ComposerEditorFormat) -> Void
    let onToggleSource: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                Button("Heading") { onFormat(.heading) }
                    .keyboardShortcut("1", modifiers: [.command, .shift])
            } label: {
                Image(systemName: "textformat.size")
            }
            .accessibilityLabel("Heading style")
            .accessibilityIdentifier("composer-heading-style")

            Button { onFormat(.strong) } label: {
                Image(systemName: "bold")
            }
            .keyboardShortcut("b", modifiers: .command)
            .accessibilityLabel("Bold")
            .accessibilityIdentifier("composer-bold")

            Button { onFormat(.emphasis) } label: {
                Image(systemName: "italic")
            }
            .keyboardShortcut("i", modifiers: .command)
            .accessibilityLabel("Italic")
            .accessibilityIdentifier("composer-italic")

            Button { onFormat(.link) } label: {
                Image(systemName: "link")
            }
            .keyboardShortcut("k", modifiers: .command)
            .accessibilityLabel("Link")
            .accessibilityIdentifier("composer-link")

            Button { onFormat(.unorderedList) } label: {
                Image(systemName: "list.bullet")
            }
            .keyboardShortcut("8", modifiers: [.command, .shift])
            .accessibilityLabel("List")
            .accessibilityIdentifier("composer-list")

            Button { onFormat(.quote) } label: {
                Image(systemName: "text.quote")
            }
            .keyboardShortcut(">", modifiers: [.command, .shift])
            .accessibilityLabel("Quote")
            .accessibilityIdentifier("composer-quote")

            Button { onFormat(.inlineCode) } label: {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
            }
            .keyboardShortcut("`", modifiers: .command)
            .accessibilityLabel("Inline Code")
            .accessibilityIdentifier("composer-inline-code")

            Button { onFormat(.fencedCode) } label: {
                Image(systemName: "curlybraces")
            }
            .accessibilityLabel("Code Block")
            .accessibilityIdentifier("composer-code-block")

            Menu {
                Button(mode == .source ? "Show Formatted Text" : "Source") {
                    onToggleSource()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .accessibilityIdentifier("composer-source-action")
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More formatting actions")
            .accessibilityIdentifier("composer-format-overflow")
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
        .font(.title3)
        .help(mode == .source ? "Show formatted text." : "Format Markdown.")
        .accessibilityIdentifier("composer-formatting-row")
    }
}

/// The model menu of the open chat.
///
/// The menu lists what the gateway reports for this chat, and nothing else.
/// It loads the list when it opens, so a chat that never opens the menu makes
/// no gateway call.
struct ComposerModelMenu: View {
    let model: ComposerModel

    var body: some View {
        Menu {
            content
                .onAppear { model.loadModels() }
        } label: {
            Label(title, systemImage: "cpu")
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .labelStyle(ComposerLabelStyle(showsTitle: model.density != .minimal))
        .disabled(!model.canChangeRuntime)
        .help(help)
        .accessibilityLabel("Model")
        .accessibilityValue(title)
    }

    private var selection: ComposerModelSelection { model.modelSelection }

    private var title: String { selection.displayName ?? "Model" }

    private var help: String {
        if let reason = model.runtimeDisabledReason { return reason }
        if selection.isDeferredToNextTurn, let pending = selection.pending {
            return "\(pending) starts with the next message."
        }
        if let pending = selection.pending { return "Changing the model to \(pending)." }
        if let current = selection.current { return "The model of this chat is \(current)." }
        return "The gateway did not report a model for this chat."
    }

    @ViewBuilder private var content: some View {
        switch model.inventory {
        case .notLoaded, .loading:
            Text("Loading models…")
        case let .failed(message):
            Text(message)
            Button("Try Again") { model.loadModels(refresh: true) }
        case let .loaded(inventory):
            if inventory.providers.isEmpty {
                Text("The gateway reported no models.")
            }
            ForEach(inventory.providers, id: \.slug) { provider in
                Section(provider.name) {
                    ForEach(provider.models, id: \.self) { name in
                        Toggle(name, isOn: binding(for: name, provider: provider.slug))
                    }
                }
            }
            Divider()
            Button("Reload Models") { model.loadModels(refresh: true) }
        }
    }

    private func binding(for name: String, provider: String) -> Binding<Bool> {
        Binding(
            get: {
                name == selection.displayName
                    && provider == (selection.pendingProvider ?? selection.provider)
            },
            set: { isOn in
                guard isOn else { return }
                model.selectModel(name, provider: provider)
            }
        )
    }
}

/// The reasoning menu of the open chat.
///
/// The choices come from the capabilities the gateway reports for the current
/// model. A model that states no reasoning support gets no choices, and the
/// menu says why.
struct ComposerReasoningMenu: View {
    let model: ComposerModel

    var body: some View {
        Menu {
            content
                .onAppear { model.loadModels() }
        } label: {
            Label(title, systemImage: "brain")
                .lineLimit(1)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .labelStyle(ComposerLabelStyle(showsTitle: model.density == .full))
        .disabled(!model.canChangeRuntime || options.unavailableReason != nil)
        .help(help)
        .accessibilityLabel("Reasoning")
        .accessibilityValue(title)
    }

    private var options: ComposerReasoningOptions { model.reasoningOptions }

    private var title: String { options.displayValue?.composerTitle ?? "Reasoning" }

    private var help: String {
        if let reason = options.unavailableReason { return reason }
        if let reason = model.runtimeDisabledReason { return reason }
        if let pending = options.pending {
            return "Changing reasoning to \(pending.composerTitle)."
        }
        if let current = options.current {
            return "Reasoning for this chat is \(current.composerTitle)."
        }
        return "The gateway did not report a reasoning value for this chat."
    }

    @ViewBuilder private var content: some View {
        if let reason = options.unavailableReason {
            Text(reason)
        } else {
            ForEach(options.choices, id: \.wireValue) { setting in
                Toggle(setting.composerTitle, isOn: binding(for: setting))
            }
        }
    }

    private func binding(for setting: ReasoningSetting) -> Binding<Bool> {
        Binding(
            get: { setting == options.displayValue },
            set: { isOn in
                guard isOn else { return }
                model.selectReasoning(setting)
            }
        )
    }
}

extension ReasoningSetting {
    /// The menu title of one reasoning value. The wire value does not change.
    var composerTitle: String {
        switch self {
        case .off:
            return "Off"
        case let .effort(effort):
            switch effort {
            case .minimal: return "Minimal"
            case .low: return "Low"
            case .medium: return "Medium"
            case .high: return "High"
            case .xhigh: return "Extra High"
            case .max: return "Maximum"
            case .ultra: return "Ultra"
            }
        }
    }
}
