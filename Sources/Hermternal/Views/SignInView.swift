import SwiftUI

struct SignInView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            HermternalMarkView(size: 80)
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
                    .disabled(!model.canSignIn)
            }
            .frame(maxWidth: 380)
            .padding(.top, 34)

            Button {
                signIn()
            } label: {
                HStack(spacing: 8) {
                    if model.isSigningIn || model.isSigningOut {
                        ProgressView().controlSize(.small)
                    }
                    Text(signInLabel)
                }
                .frame(maxWidth: 356, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canSignIn)
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

    private var signInLabel: String {
        if model.isSigningOut { return "Signing Out…" }
        if model.isSigningIn { return "Waiting for browser…" }
        return "Sign In"
    }

    private func signIn() {
        guard model.canSignIn else { return }
        Task {
            await model.signIn()
        }
    }
}
