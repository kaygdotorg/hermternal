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
    }
}
