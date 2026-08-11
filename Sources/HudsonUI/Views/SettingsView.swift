import SwiftUI

/// The Settings sheet — AI setup (turn on summarize/draft/ask with your own
/// key, or a local model) plus account management (Task 5: "Disconnect
/// account"). Presented from the sidebar's gear.
struct SettingsView: View {
    @Bindable var settings: SettingsModel
    /// The connected account's address, or `nil` when there isn't one
    /// (defensive — `SettingsView` is only ever presented from inside the
    /// assembled mailbox, which `RootView`'s onboarding gate keeps un-
    /// mounted without an account, but this stays a plain optional rather
    /// than trust that invariant). `nil` hides the disconnect section
    /// entirely — there is nothing to disconnect.
    let accountEmail: String?
    /// Runs `AppModel.disconnectAccount()` — called only after the user
    /// confirms in the dialog below. This view makes no `AppModel`/Store
    /// calls of its own (matches every other Hudson view's "presentational
    /// only" contract), so the actual disconnect logic lives entirely on
    /// the host's side of this closure.
    let onDisconnect: () -> Void
    let onClose: () -> Void

    /// Whether the "Disconnect <email>?" confirmation is showing — view-
    /// local, like `OnboardingView`'s BYO draft fields, since there's
    /// nowhere else for a yes/no dialog's presentation state to live.
    @State private var isConfirmingDisconnect = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.unit * 4) {
            header

            Text("AI features")
                .font(Typography.ui(13, .semibold))
                .foregroundStyle(Palette.ink)

            Text(
                "Summarize, draft, and ask run on your OWN key — Anthropic, or a "
                    + "local model (Ollama / LM Studio) that never leaves your Mac. "
                    + "Nothing is sent anywhere unless you explicitly invoke it.")
                .font(Typography.ui(12))
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            providerPicker

            if settings.provider == .anthropic {
                secureField("Anthropic API key", text: $settings.apiKey, prompt: "sk-ant-…")
            } else {
                themedField("Base URL", text: $settings.baseURL, prompt: "http://localhost:11434/v1")
                themedField("Model", text: $settings.model, prompt: "llama3.1")
                secureField("API key (optional for local)", text: $settings.apiKey, prompt: "leave blank for Ollama")
            }

            if let banner = settings.banner {
                Text(banner)
                    .font(Typography.ui(12, .medium))
                    .foregroundStyle(Palette.accent)
            }

            HStack(spacing: Metrics.unit * 2) {
                PrimaryButton(title: settings.isEnabled ? "Update" : "Enable AI") {
                    Task { await settings.save() }
                }
                if settings.isEnabled {
                    QuietButton(title: "Turn off") { Task { await settings.disable() } }
                }
                Spacer(minLength: 0)
                QuietButton(title: "Done", action: onClose)
            }
            .padding(.top, Metrics.unit)

            if let accountEmail {
                accountSection(accountEmail)
            }
        }
        .padding(Metrics.unit * 5)
        .frame(width: 460)
        .background(Palette.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusLarge))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusLarge)
                .stroke(Palette.borderStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
        .task { await settings.load() }
        .confirmationDialog(
            "Disconnect \(accountEmail ?? "")?",
            isPresented: $isConfirmingDisconnect,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive, action: onDisconnect)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hudson will forget this account on this Mac. You can reconnect anytime.")
        }
    }

    /// "Disconnect <email>" (Task 5) — a thin rule to separate it from the
    /// AI section above, then a single low-emphasis, danger-colored button
    /// that opens the confirmation dialog attached to `body`. Tapping never
    /// disconnects directly: `onDisconnect` only runs once the dialog's
    /// "Disconnect" choice is picked, so a stray click can't silently sign
    /// the user out.
    private func accountSection(_ email: String) -> some View {
        VStack(alignment: .leading, spacing: Metrics.unit * 3) {
            Rectangle()
                .fill(Palette.border)
                .frame(height: 1)

            Text("Account")
                .font(Typography.ui(13, .semibold))
                .foregroundStyle(Palette.ink)

            Button(action: { isConfirmingDisconnect = true }) {
                Text("Disconnect \(email)")
                    .font(Typography.ui(13, .medium))
                    .foregroundStyle(Palette.danger)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, Metrics.unit)
    }

    private var header: some View {
        HStack {
            Text("Settings")
                .font(Typography.serif(22, .semibold))
                .foregroundStyle(Palette.ink)
            Spacer()
            if settings.isEnabled {
                Text("AI on")
                    .font(Typography.ui(11, .medium))
                    .foregroundStyle(Palette.accentInk)
                    .padding(.horizontal, Metrics.unit * 2)
                    .padding(.vertical, 2)
                    .background(Palette.accent)
                    .clipShape(Capsule())
            }
        }
    }

    private var providerPicker: some View {
        HStack(spacing: Metrics.unit) {
            ForEach(SettingsModel.Provider.allCases) { option in
                let isSelected = settings.provider == option
                Button { settings.provider = option } label: {
                    Text(option.label)
                        .font(Typography.ui(12, .medium))
                        .foregroundStyle(isSelected ? Palette.accentInk : Palette.inkSecondary)
                        .padding(.horizontal, Metrics.unit * 3)
                        .padding(.vertical, Metrics.unit * 2)
                        .frame(maxWidth: .infinity)
                        .background(isSelected ? Palette.accent : Palette.bgHover)
                        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusMedium))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func themedField(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: Metrics.unit) {
            Text(label).font(Typography.ui(11, .medium)).foregroundStyle(Palette.inkTertiary)
            TextField("", text: text, prompt: Text(prompt).foregroundStyle(Palette.inkTertiary))
                .textFieldStyle(.plain)
                .font(Typography.ui(13))
                .foregroundStyle(Palette.ink)
                .padding(Metrics.unit * 2)
                .background(Palette.bgSunken)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusMedium))
        }
    }

    private func secureField(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: Metrics.unit) {
            Text(label).font(Typography.ui(11, .medium)).foregroundStyle(Palette.inkTertiary)
            SecureField("", text: text, prompt: Text(prompt).foregroundStyle(Palette.inkTertiary))
                .textFieldStyle(.plain)
                .font(Typography.ui(13))
                .foregroundStyle(Palette.ink)
                .padding(Metrics.unit * 2)
                .background(Palette.bgSunken)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusMedium))
        }
    }
}
