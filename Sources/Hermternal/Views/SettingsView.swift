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
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SettingsSourceList(selection: $selection)
                // `.toolbar(removing: .sidebarToggle)` removes SwiftUI's
                // default toggle while keeping the toolbar and traffic lights.
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            SettingsDetailView(
                section: selection ?? .appearance,
                appearance: appearance,
                model: model,
                registry: registry
            )
            .frame(
                minWidth: 480,
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .topLeading
            )
        }
        .frame(
            minWidth: 700,
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }
}

private enum SettingsSection: String, CaseIterable, Hashable, Identifiable {
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

private struct SettingsSourceList: View {
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
    }
}

private struct SettingsDetailView: View {
    let section: SettingsSection
    @Bindable var appearance: AppearanceSettings
    @Bindable var model: AppModel
    let registry: CapabilityRegistry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(section.title)
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 6)

            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
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

    private var frostBinding: Binding<Double> {
        Binding(
            get: { appearance.windowFrost },
            set: { appearance.previewWindowFrost($0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Theme", selection: $appearance.mode) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Chat Window") {
                    LabeledContent {
                        HStack {
                            Slider(
                                value: frostBinding,
                                in: 0...1,
                                onEditingChanged: { editing in
                                    if !editing {
                                        appearance.persistWindowFrost()
                                    }
                                }
                            )
                            Text(
                                appearance.windowFrost.formatted(
                                    .percent.precision(.fractionLength(0))
                                )
                            )
                            .monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                        }
                    } label: {
                        Text("Frost")
                        Text(
                            "Applies to the chat window only. At 0% the desktop shows through "
                                + "the window; at 100% the window is a frosted material."
                        )
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                Spacer()
                Button("Reset to Defaults") {
                    appearance.resetToDefaults()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
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
                    ProgressView(value: model.cacheProgress)
                        .accessibilityLabel("Chat cache progress")
                        .accessibilityValue(
                            "\(model.cacheCachedCount) of \(model.cacheTotalCount) chats"
                        )
                    LabeledContent("Disk usage", value: sizeText)
                }

                Section {
                    HStack {
                        if model.isCacheWarming {
                            ProgressView()
                                .controlSize(.small)
                            Text("Caching in the background…")
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
