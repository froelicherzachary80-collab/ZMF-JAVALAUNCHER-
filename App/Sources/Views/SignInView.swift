import SwiftUI

/// One place to sign in: Microsoft's own sign-in sheet, or a short code you
/// enter at microsoft.com/link on any device.
struct SignInView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var showSetup = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Image(systemName: "person.badge.key.fill").font(.system(size: 44)).foregroundStyle(Theme.accent)
                    Text("Sign in with your Microsoft account").font(.title3.bold()).multilineTextAlignment(.center)
                    Text("Use the account that owns Minecraft: Java Edition. You sign in on Microsoft's page — ZMF never sees your password.")
                        .font(.footnote).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)

                    if store.effectiveClientID.isEmpty {
                        setupNeeded
                    } else if let code = model.accounts.deviceCode {
                        deviceCodeCard(code)
                    } else {
                        Button {
                            Task { await model.accounts.signIn(clientID: store.effectiveClientID); if model.accounts.active != nil { dismiss() } }
                        } label: { Label("Continue with Microsoft", systemImage: "safari") }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(model.accounts.busy)
                        Button {
                            model.accounts.startDeviceCodeSignIn(clientID: store.effectiveClientID)
                        } label: { Label("Use a sign-in code instead", systemImage: "number.square") }
                            .buttonStyle(.bordered)
                            .disabled(model.accounts.busy)
                    }

                    if let err = model.accounts.lastError {
                        Card { Label(err, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(Theme.warning) }
                    }
                    DisclosureGroup("Advanced: Microsoft app ID", isExpanded: $showSetup) { setupSteps }
                        .font(.footnote)
                }
                .padding()
            }
            .background(Theme.background.ignoresSafeArea())
            .toolbar { Button("Close") { model.accounts.cancelDeviceCode(); dismiss() } }
            .onChange(of: model.accounts.active?.id) { _, id in if id != nil { dismiss() } }
        }
    }

    private func deviceCodeCard(_ code: DeviceCodeChallenge) -> some View {
        Card {
            VStack(spacing: 12) {
                Text("Enter this code at").font(.subheadline)
                Text(code.verification_uri.replacingOccurrences(of: "https://", with: "")).font(.headline)
                Text(code.user_code).font(.system(size: 34, weight: .bold, design: .monospaced)).textSelection(.enabled)
                Button {
                    UIPasteboard.general.string = code.user_code
                    if let url = URL(string: code.verification_uri) { openURL(url) }
                } label: { Label("Copy code & open Microsoft", systemImage: "doc.on.doc") }
                    .buttonStyle(PrimaryButtonStyle())
                HStack { ProgressView(); Text("Waiting for you to finish signing in…").font(.caption) }
                Text("You can also enter the code on a computer or another phone.").font(.caption2).foregroundStyle(Theme.textSecondary)
                Button("Cancel", role: .cancel) { model.accounts.cancelDeviceCode() }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var setupNeeded: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("One-time setup needed", systemImage: "wrench.and.screwdriver").font(.headline)
                Text("This build has no Microsoft app ID. Microsoft requires every launcher to use its own approved ID; paste one below (your own, or one a friend's ZMF build uses).")
                    .font(.footnote)
                TextField("Application (client) ID", text: $store.settings.microsoftClientID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.system(.footnote, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var setupSteps: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Application (client) ID", text: $store.settings.microsoftClientID)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(.system(.footnote, design: .monospaced))
            Text("""
            To create your own ID (once, from Safari):
            1. portal.azure.com › Microsoft Entra ID › App registrations › New registration. Supported accounts: "Personal Microsoft accounts only".
            2. Authentication › Add platform › Mobile and desktop › custom redirect URI zmflauncher://auth.
            3. Authentication › Allow public client flows: Yes (for sign-in codes).
            4. Copy the Application (client) ID here, or into the repository variable ZMF_MSA_CLIENT_ID so every build has it.
            5. Request Minecraft API access for the ID at aka.ms/mce-reviewappid (Microsoft's rule; until approved, step 3 of sign-in returns 403).
            """).font(.caption).foregroundStyle(Theme.textSecondary)
        }
    }
}
