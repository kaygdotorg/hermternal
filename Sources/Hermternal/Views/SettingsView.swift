import SwiftUI

struct SettingsView: View {
    @Bindable var appearance: AppearanceSettings
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            AppearanceSettingsView(appearance: appearance)
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            CacheSettingsView(model: model)
                .tabItem { Label("Cache", systemImage: "internaldrive") }
        }
        .frame(width: 460)
        .scenePadding()
        .clearAppKitBackground()
        .glassSurface(intensity: appearance.auxiliaryGlass)
    }
}

private struct AppearanceSettingsView: View {
    @Bindable var appearance: AppearanceSettings

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

            Section("Liquid Glass") {
                GlassSlider(
                    title: "Sidebar",
                    help: "How much the desktop shows through the chat list.",
                    value: $appearance.sidebarGlass
                )
                GlassSlider(
                    title: "Chat",
                    help: "Lower this if long messages are hard to read.",
                    value: $appearance.chatGlass
                )
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset to Defaults") {
                        appearance.resetToDefaults()
                    }
                }
            }
        }
        .formStyle(.grouped)
        // Otherwise the Form's own backing hides the window glass.
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
                Text(
                    model.cacheEnabled
                        ? "Recent transcripts are stored on this Mac so switching chats is immediate."
                        : "Chats load from the server each time you open them."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
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

private struct GlassSlider: View {
    let title: String
    let help: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(value.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: 0...1) {
                EmptyView()
            } minimumValueLabel: {
                Image(systemName: "square.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } maximumValueLabel: {
                Image(systemName: "square.on.square.dashed")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(help)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
