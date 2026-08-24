import SwiftUI
import HermternalCore

struct SettingsView: View {
    @Bindable var appearance: AppearanceSettings
    @Bindable var model: AppModel
    let registry: CapabilityRegistry

    @State private var selection: SettingsSection? = .appearance

    init(
        appearance: AppearanceSettings,
        model: AppModel,
        registry: CapabilityRegistry = CapabilityRegistry()
    ) {
        self.appearance = appearance
        self.model = model
        self.registry = registry
    }

    var body: some View {
        SettingsSplitView(
            appearance: appearance,
            model: model,
            registry: registry,
            selection: $selection
        )
        .frame(
            minWidth: 700,
            maxWidth: CGFloat.infinity,
            maxHeight: CGFloat.infinity,
            alignment: .topLeading
        )
    }

}

enum SettingsSection: String, CaseIterable, Hashable, Identifiable {
    case appearance
    case gateway
    case cache
    case modules

    var id: Self { self }

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .gateway: "Gateway"
        case .cache: "Cache"
        case .modules: "Modules"
        }
    }

    var systemImage: String {
        switch self {
        case .appearance: "paintbrush"
        case .gateway: "network"
        case .cache: "internaldrive"
        case .modules: "puzzlepiece.extension"
        }
    }
}

struct SettingsSourceList: View {
    @Binding var selection: SettingsSection?

    var body: some View {
        List(selection: $selection) {
            ForEach(SettingsSection.allCases) { section in
                Label(section.title, systemImage: section.systemImage)
                    .accessibilityLabel(section.title)
                    .accessibilityValue(selection == section ? "Selected" : "")
                    .tag(section)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        // Clear the traffic lights; the hosting controller drops the titlebar
        // safe area, so this is the only top inset the list gets.
        .padding(.top, 46)
    }
}

struct SettingsDetailView: View {
    let section: SettingsSection
    @Bindable var appearance: AppearanceSettings
    @Bindable var model: AppModel
    let registry: CapabilityRegistry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(section.title)
                .font(.title)
                .fontWeight(.semibold)
                .padding(.horizontal, 20)
                .padding(.top, 20)

            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // Top inset comes from the heading's own padding; the hosting
        // controller already drops the titlebar safe area.
    }

    @ViewBuilder
    private var detailContent: some View {
        switch section {
        case .appearance:
            AppearanceSettingsView(appearance: appearance)
        case .gateway:
            GatewaySettingsView(
                status: model.gatewayStatus,
                onSelectMethod: model.setAuthenticationMethod
            )
        case .cache:
            CacheSettingsView(model: model)
        case .modules:
            ModulesSettingsView(registry: registry)
        }
    }
}

private struct AppearanceSettingsView: View {
    @Bindable var appearance: AppearanceSettings

    private var opacityBinding: Binding<Double> {
        Binding(
            get: { appearance.backgroundOpacity },
            set: { appearance.previewBackgroundOpacity($0) }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $appearance.mode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                LabeledContent {
                    HStack {
                        Slider(
                            value: opacityBinding,
                            in: 0...1,
                            onEditingChanged: { editing in
                                if !editing {
                                    appearance.persistBackgroundOpacity()
                                }
                            }
                        )
                        // The dial is a plain 0...1 opacity, so VoiceOver's
                        // own percentage is the truth and needs no override.
                        Text(
                            appearance.backgroundOpacity,
                            format: .percent.precision(.fractionLength(0))
                        )
                        // Monospaced digits so the readout cannot shimmy
                        // while the thumb is moving.
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                    }
                } label: {
                    Text("Background Opacity")
                    Text(
                        "How solid the chat window is. Lower lets more of the "
                            + "desktop show through the blur; 100% hides it "
                            + "entirely."
                    )
                }

                Toggle(isOn: $appearance.usesLiquidGlass) {
                    Text("Refract the desktop instead of blurring it")
                    Text(
                        "Replaces the frosted blur behind the chat window with "
                            + "Liquid Glass. Glass adjusts the luminosity of "
                            + "whatever sits behind the window, so text can "
                            + "read softer at low opacity."
                    )
                }
            } header: {
                Text("Chat Window")
            } footer: {
                HStack {
                    Spacer()
                    Button("Reset to Defaults") {
                        appearance.resetToDefaults()
                    }
                }
            }

        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

private struct CacheSettingsView: View {
    @Bindable var model: AppModel

    private var cacheBinding: Binding<Bool> {
        Binding(
            get: { model.cacheEnabled },
            set: { model.setCacheEnabled($0) }
        )
    }

    private var sizeText: String {
        ByteCountFormatter.string(
            fromByteCount: model.cacheBytes,
            countStyle: .file
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle("Cache chat history locally", isOn: cacheBinding)
            }

            if model.cacheEnabled {
                Section("Progress") {
                    LabeledContent("Cached") {
                        Text("\(model.cacheCachedCount) of \(model.cacheTotalCount) chats")
                            .monospacedDigit()
                    }
                    if model.cacheTotalCount > 0 {
                        ProgressView(value: model.cacheProgress)
                            .accessibilityLabel("Chat cache progress")
                            .accessibilityValue(
                                "\(model.cacheCachedCount) of \(model.cacheTotalCount) chats"
                            )
                    } else {
                        Text("No chats are available to cache yet.")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Disk usage", value: sizeText)
                }

                Section {
                    HStack {
                        if model.isCacheWarming && model.cacheTotalCount > 0 {
                            ProgressView()
                                .controlSize(.small)
                        }
                        if model.isCacheWarming {
                            Text(
                                model.cacheTotalCount > 0
                                    ? "Caching in the background…"
                                    : "Caching will begin after chats load."
                            )
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Rebuild Cache") {
                            model.rebuildCache()
                        }
                        .disabled(model.isCacheWarming || model.cacheTotalCount == 0)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

private struct ModulesSettingsView: View {
    let registry: CapabilityRegistry

    var body: some View {
        Form {
            if registry.capabilities.isEmpty {
                Section {
                    Text("No optional capability modules are installed.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(registry.capabilities) { capability in
                        CapabilityRow(capability: capability)
                    }
                } header: {
                    Text("Optional capabilities")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

private struct CapabilityRow: View {
    let capability: CapabilityDescriptor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(capability.name) {
                Text(capability.state.label)
                    .foregroundStyle(stateColor)
            }

            Text(capability.purpose)
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent("Source", value: capability.implementationSource.rawValue)

            if !capability.dependencies.isEmpty {
                LabeledContent("Dependencies") {
                    Text(capability.dependencies.map(\.rawValue).joined(separator: ", "))
                        .foregroundStyle(.secondary)
                }
            }

            if let reason = capability.state.reason {
                LabeledContent("Reason") {
                    Text(reason)
                        .foregroundStyle(.secondary)
                }
            }

            if let relaunchNote = capability.relaunchNote {
                Label(relaunchNote, systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(capability.name), \(capability.state.label)")
        .accessibilityHint(capability.purpose)
    }

    private var stateColor: Color {
        switch capability.state {
        case .available: .green
        case .omitted: .secondary
        case .unavailable: .orange
        }
    }
}
