import SwiftUI

struct SignInView: View {
    @Bindable var model: AppModel
    @State private var isWorking = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "sparkle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tint)
                .padding(.bottom, 18)
                .accessibilityHidden(true)

            Text("Hermternal")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
            Text("A native client for your Hermes agent.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 8) {
                Text("Server")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("https://hermes.example.org", text: $model.serverText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { signIn() }
            }
            .frame(maxWidth: 380)
            .padding(.top, 34)

            Button {
                signIn()
            } label: {
                HStack(spacing: 8) {
                    if isWorking { ProgressView().controlSize(.small) }
                    Text(isWorking ? "Waiting for browser…" : "Sign In")
                }
                .frame(maxWidth: 356, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isWorking)
            .padding(.top, 16)

            // Sign-in leaves the app: the gateway brokers the flow through
            // the system browser, so say so rather than looking stalled.
            Text("Opens your browser to complete single sign-on.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 10)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func signIn() {
        guard !isWorking else { return }
        isWorking = true
        Task {
            await model.signIn()
            isWorking = false
        }
    }
}
