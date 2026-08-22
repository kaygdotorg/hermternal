import HermternalCore
import SwiftUI

/// Read-only gateway status and authentication-method selection.
///
/// Composition owns discovery and persistence. This view only renders the
/// supplied snapshot and reports a requested method change.
struct GatewaySettingsView: View {
    let status: GatewayStatus
    let onSelectMethod: (AuthMethod) -> Void

    var body: some View {
        Form {
            Section("Gateway") {
                LabeledContent("URL", value: status.url.absoluteString)
                LabeledContent("Host", value: status.host)
                LabeledContent("Connection") {
                    Text(status.connection.displayName)
                        .foregroundStyle(connectionColor)
                }

                if let provider = status.provider {
                    LabeledContent("Provider", value: provider.displayName)
                } else {
                    LabeledContent("Provider", value: "Unavailable")
                    Text(
                        "This gateway does not advertise provider details. "
                            + "The existing browser sign-in flow remains available."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section("Authentication") {
                if status.availableMethods.count == 1,
                   let method = status.availableMethods.first {
                    LabeledContent("Method") {
                        Text("\(method.displayName) (only supported method)")
                    }
                } else if status.availableMethods.count > 1 {
                    Picker(
                        "Method",
                        selection: Binding(
                            get: { status.method },
                            set: { onSelectMethod($0) }
                        )
                    ) {
                        ForEach(status.availableMethods) { method in
                            Text(method.displayName).tag(method)
                        }
                    }
                } else {
                    LabeledContent("Method", value: "No supported method advertised")
                }
            }

            Section {
                Text("Gateway switching is managed through accounts and profiles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var connectionColor: Color {
        switch status.connection {
        case .ready: .green
        case .failed: .orange
        case .signedOut, .connecting: .secondary
        }
    }
}
