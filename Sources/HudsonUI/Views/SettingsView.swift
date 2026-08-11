import SwiftUI

/// The Settings sheet — currently AI setup (turn on summarize/draft/ask with
/// your own key, or a local model). Presented from the sidebar's gear.
struct SettingsView: View {
    @Bindable var settings: SettingsModel
    let onClose: () -> Void

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
