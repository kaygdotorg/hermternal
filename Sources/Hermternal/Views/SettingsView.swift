import SwiftUI

struct SettingsView: View {
    @Bindable var appearance: AppearanceSettings

    var body: some View {
        TabView {
            AppearanceSettingsView(appearance: appearance)
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
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
