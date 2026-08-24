import SwiftUI
import HermternalCore

struct SettingsView: View {
    @Bindable var appearance: AppearanceSettings
    @Bindable var model: AppModel
    let registry: CapabilityRegistry
    let debugModules: any DebugModuleCapability

    @State private var selection: SettingsSection? = .appearance

    init(
        appearance: AppearanceSettings,
        model: AppModel,
        registry: CapabilityRegistry = CapabilityRegistry(),
        debugModules: any DebugModuleCapability = OmittedDebugModuleCapability()
    ) {
        self.appearance = appearance
        self.model = model
        self.registry = registry
        self.debugModules = debugModules
    }

    var body: some View {
        SettingsSplitView(
            appearance: appearance,
            model: model,
            registry: registry,
            debugModules: debugModules,
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
    let debugModules: any DebugModuleCapability

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
            ModulesSettingsView(registry: registry, debugModules: debugModules)
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
    let debugModules: any DebugModuleCapability

    var body: some View {
        Form {
            // Absent, not merely disabled. The capability reports `.available`
            // only when the composition root handed it `debugMode == true`
            // from its single HERMTERNAL_DEBUG read, and an omitted capability
            // reports the same unavailable state. No view reads the
            // environment, so a launch without the flag renders exactly the
            // inventory below and nothing else.
            if debugModules.state.isAvailable, !debugModules.modules.isEmpty {
                DebugModulesGroup(capability: debugModules)
            }

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

/// The instrumentation group inside the Modules pane.
///
/// Every module is on by default in debug mode; the outer gate lives in the
/// injected capability, so nothing in this file can raise a module during a
/// normal launch, and the only write this surface performs is an explicit
/// toggle.
private struct DebugModulesGroup: View {
    let capability: any DebugModuleCapability

    /// The pane holds the display copy of the gate mask. The capability stays
    /// a plain reference behind an existential rather than an observable view
    /// model on purpose: observing it would charge `record(_:for:)` on the
    /// very hot paths these modules measure. A toggle writes through and then
    /// re-reads the gate, so a refused write cannot desync the switch.
    @State private var enabledMask: UInt64
    /// Refreshed on a one-second cadence, and only while this pane is on
    /// screen. Recording a sample therefore pays nothing for the readout, and
    /// nothing polls once Settings closes.
    @State private var metrics: DebugMetricsSnapshot?

    init(capability: any DebugModuleCapability) {
        self.capability = capability
        _enabledMask = State(initialValue: capability.gate.rawValue)
        _metrics = State(initialValue: capability.metrics)
    }

    var body: some View {
        Section {
            ForEach(capability.modules) { module in
                Toggle(isOn: binding(for: module)) {
                    Text(module.title)
                    Text(module.description)
                }
            }
        } header: {
            Text("Debug Modules")
        } footer: {
            Text(
                "On by default because HERMTERNAL_DEBUG=1 is set. Without that "
                    + "flag this group is absent and every module stays off, "
                    + "whatever an earlier debug session stored."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section {
            // Sample size leads the section so it is read before the
            // statistics it qualifies. The refresh lives on a row rather than
            // on the Section so the Form cannot apply it per subview.
            LabeledContent("Sample size") {
                sampleSizeValue
            }
            .task { await followMeasurements() }

            statisticRow(
                "Publish to visible, median",
                latency(\.publishToVisibleMedianNanoseconds)
            )
            statisticRow(
                "Publish to visible, p90",
                latency(\.publishToVisibleP90Nanoseconds)
            )
            statisticRow(
                "Publish to visible, maximum",
                latency(\.publishToVisibleMaxNanoseconds)
            )
            statisticRow(
                "Selections",
                count(\.selectionCount, from: .sidebarAndFolderSelection)
            )
            statisticRow(
                "Publications",
                count(\.publicationCount, from: .switchPhases)
            )
            statisticRow("Largest row", largestRow)
        } header: {
            Text("Measurements")
        } footer: {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "Every statistic is carried on the samples Visible paint "
                        + "records, so its switch governs the whole section. "
                        + "Statistics summarise the samples collected since "
                        + "the last clear, so a handful of samples is a "
                        + "reading rather than a stable measurement. A value "
                        + "reads Unavailable when the module producing it is "
                        + "off or has measured nothing — never zero, which "
                        + "would claim a measurement that never ran."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack {
                    Spacer()
                    Button("Clear Samples") {
                        capability.clearMetrics()
                        metrics = capability.metrics
                    }
                    .disabled(metrics == nil)
                }
            }
        }
    }

    @ViewBuilder
    private var sampleSizeValue: some View {
        if let metrics {
            Text(metrics.sampleSize.formatted())
                .monospacedDigit()
        } else {
            Text("No samples collected")
                .foregroundStyle(.secondary)
        }
    }

    private func binding(for module: DebugModule) -> Binding<Bool> {
        Binding(
            get: { isEnabled(module) },
            set: { enabled in
                capability.setEnabled(enabled, for: module)
                // The capability is the authority on the mask: an unavailable
                // one refuses the write, and the switch must follow it rather
                // than its own optimism.
                enabledMask = capability.gate.rawValue
                metrics = capability.metrics
            }
        )
    }

    private func isEnabled(_ module: DebugModule) -> Bool {
        (enabledMask & module.bit) != 0
    }

    private func latency(_ keyPath: KeyPath<DebugMetricsSnapshot, UInt64>) -> DebugStatistic {
        statistic(from: .visiblePaint) { metrics in
            let milliseconds = Double(metrics[keyPath: keyPath]) / 1_000_000
            return "\(milliseconds.formatted(.number.precision(.fractionLength(1)))) ms"
        }
    }

    /// The snapshot already reports nil for a count whose producer module was
    /// off across the retained samples, so an absent value and a disabled
    /// module both resolve to unavailable rather than to zero.
    private func count(
        _ keyPath: KeyPath<DebugMetricsSnapshot, Int?>,
        from module: DebugModule
    ) -> DebugStatistic {
        statistic(from: module) { metrics in
            metrics[keyPath: keyPath]?.formatted()
        }
    }

    private var largestRow: DebugStatistic {
        statistic(from: .textLayoutAttribution) { metrics in
            // A row of zero characters cannot be the widest one in a transcript
            // that was laid out, so zero means the probe has attributed none.
            guard let characters = metrics.largestRowCharacterCount, characters > 0 else {
                return nil
            }
            return "\(characters.formatted()) characters"
        }
    }

    private func statistic(
        from module: DebugModule,
        _ value: (DebugMetricsSnapshot) -> String?
    ) -> DebugStatistic {
        // Off means unmeasured even when older samples are still in the ring;
        // printing those would pass a stale number off as a live one.
        guard isEnabled(module) else {
            return .unavailable("\(module.title) is off")
        }
        // Every statistic rides on the samples Visible paint records, so its
        // bit gates the whole readout rather than only the durations. Saying
        // "nothing measured yet" here would blame an enabled module for a
        // sample stream that was switched off.
        guard isEnabled(.visiblePaint) else {
            return .unavailable("\(DebugModule.visiblePaint.title) is off")
        }
        guard let metrics, let text = value(metrics) else {
            return .unavailable("nothing measured yet")
        }
        return .measured(text)
    }

    private func statisticRow(_ label: String, _ statistic: DebugStatistic) -> some View {
        LabeledContent(label) {
            switch statistic {
            case let .measured(text):
                // Monospaced digits so a refreshing value cannot shift the row.
                Text(text)
                    .monospacedDigit()
            case let .unavailable(reason):
                Text("Unavailable — \(reason)")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @MainActor
    private func followMeasurements() async {
        while !Task.isCancelled {
            metrics = capability.metrics
            enabledMask = capability.gate.rawValue
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

/// A statistic is either measured or unavailable. There is deliberately no
/// zero case: a module that is off measured nothing, and printing zero would
/// be a claim about a measurement that never ran.
private enum DebugStatistic {
    case measured(String)
    case unavailable(String)
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
