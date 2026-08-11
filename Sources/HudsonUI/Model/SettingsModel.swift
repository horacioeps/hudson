import AIKit
import Foundation
import GmailKit
import Store

/// Backs the in-app Settings sheet — currently AI configuration (provider,
/// key, model, opt-in). Writes the SAME `ai_config` rows + `LLMKeyStore` entry
/// the CLI's `hudson ai config` does (the `base_url` provider encoding is
/// mirrored from `AIBootstrap`'s decoder), so the Summarize chip's fail-closed
/// `AIBootstrap.makeSummarize` gate lights up the moment you save.
@MainActor
@Observable
public final class SettingsModel {
    public enum Provider: String, CaseIterable, Identifiable, Sendable {
        case anthropic
        case openAICompat
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .anthropic: return "Anthropic (Claude)"
            case .openAICompat: return "Local / OpenAI-compatible"
            }
        }
        /// The key `LLMKeyStore`/`ai_config` file this provider under — must
        /// match `AIBootstrap`'s `SummarizeProviderSelection.keychainProvider`.
        var keychainProvider: String {
            switch self {
            case .anthropic: return "anthropic"
            case .openAICompat: return "openai-compat"
            }
        }
    }

    public var provider: Provider = .anthropic
    public var apiKey: String = ""
    /// Only used by `.openAICompat` — defaults to Ollama's local endpoint so
    /// "Local" works out of the box with zero typing.
    public var baseURL: String = "http://localhost:11434/v1"
    /// The model for `.openAICompat` (e.g. `llama3.1`, `gpt-4o-mini`). For
    /// `.anthropic` the per-feature defaults (Haiku for summarize, Sonnet for
    /// draft/ask) are used automatically.
    public var model: String = ""

    public private(set) var banner: String?

    private let database: HudsonDatabase
    private let account: String
    private let keyStore: any LLMKeyStore

    public init(
        database: HudsonDatabase, account: String,
        keyStore: any LLMKeyStore = KeychainLLMKeyStore()
    ) {
        self.database = database
        self.account = account
        self.keyStore = keyStore
    }

    /// Whether AI is currently enabled (summarize opted in) — drives the
    /// sheet's "Enabled ✓" vs "off" hint.
    public private(set) var isEnabled = false

    /// Prefill the form from the stored `summarize` config, if any.
    public func load() async {
        guard
            let config = try? await database.aiConfig(
                feature: AIFeature.summarize.rawValue, account: account)
        else { return }
        isEnabled = config.optIn
        if let base = config.baseURL, base.hasPrefix("openai-compat") {
            provider = .openAICompat
            let parts = base.split(separator: "|", maxSplits: 1)
            if parts.count > 1 { baseURL = String(parts[1]) }
            model = config.model
        } else {
            provider = .anthropic
        }
        apiKey = (try? keyStore.key(provider: provider.keychainProvider)) ?? ""
    }

    /// Enable AI: store the key and opt every feature in with this provider.
    public func save() async {
        let baseEncoding: String?
        let modelsByFeature: [(AIFeature, String)]
        switch provider {
        case .anthropic:
            baseEncoding = nil  // a nil/empty base_url decodes to .anthropic
            modelsByFeature = [
                (.summarize, "claude-haiku-4-5"),
                (.draft, "claude-sonnet-5"), (.ask, "claude-sonnet-5"),
                // Draft-in-voice distills a style card from sent mail with its
                // OWN opt-in — enable it alongside draft so the button works.
                (.voiceProfile, "claude-sonnet-5"),
            ]
        case .openAICompat:
            let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            baseEncoding = trimmedURL.isEmpty ? "openai-compat" : "openai-compat|\(trimmedURL)"
            let chosen = model.trimmingCharacters(in: .whitespacesAndNewlines)
            modelsByFeature = [
                (.summarize, chosen), (.draft, chosen), (.ask, chosen), (.voiceProfile, chosen),
            ]
        }

        do {
            let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedKey.isEmpty {
                try keyStore.saveKey(trimmedKey, provider: provider.keychainProvider)
            }
            for (feature, model) in modelsByFeature {
                try await database.setAIConfig(
                    feature: feature.rawValue, model: model, baseURL: baseEncoding,
                    optIn: true, account: account)
            }
            isEnabled = true
            banner = "AI enabled."
        } catch {
            banner = "Couldn't save settings."
        }
    }

    /// Turn AI back off (opt every feature out — the key stays in the Keychain
    /// so re-enabling doesn't require re-pasting it).
    public func disable() async {
        for feature in [AIFeature.summarize, .draft, .ask, .voiceProfile] {
            try? await database.setAIConfig(
                feature: feature.rawValue, model: "", baseURL: nil, optIn: false, account: account)
        }
        isEnabled = false
        banner = "AI turned off."
    }
}
