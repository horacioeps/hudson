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

    /// Store the provider configuration, and — only if `optIn` — consent to
    /// sending mail content to it.
    ///
    /// `optIn` exists so onboarding can offer to keep a key without also
    /// granting egress: pasting an API key and agreeing that your email may be
    /// sent to that provider are two different decisions, and the onboarding
    /// step is not a place to conflate them. The Settings sheet keeps calling
    /// this with the default `true`, where the button genuinely does say
    /// "Enable AI".
    ///
    /// Opt-in is additionally refused when the chosen provider needs a key and
    /// none is available. Writing `opt_in = 1` with no key would leave every
    /// AI surface enabled-looking and failing at the point of use, and — worse
    /// for a fail-closed design — would put the account in a state where
    /// merely pasting a key later starts egressing with no further consent.
    public func save(optIn: Bool = true) async {
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
            // What "configured enough to consent" means, per provider.
            //
            // Anthropic needs a key. A key already in the Keychain counts —
            // this method is also how someone changes their model without
            // re-pasting one.
            //
            // OpenAI-compatible may legitimately be KEYLESS (a local Ollama or
            // LM Studio server), but it must not therefore skip validation
            // altogether. An empty Base URL encodes as the bare string
            // `"openai-compat"`, which `AIBootstrap` decodes to
            // `baseURL: nil`, and `OpenAICompatProvider` then falls back to
            // `https://api.openai.com/v1`. Waiving the check for this provider
            // meant the ONE choice whose entire premise is "nothing leaves
            // this machine" was the one that could opt in with no key, no
            // endpoint, and no model — silently pointed at a cloud host. So it
            // requires a usable endpoint and model instead of a key.
            // Note on the stored-key branch: `LLMKeyStore` is scoped per
            // PROVIDER, not per account, and disconnecting an account does not
            // remove it. So a key left by a previous account would count here
            // for a brand-new one. That is fine for the Settings sheet, where
            // the field is populated from the same store and the user can see
            // what they are consenting against — but NOT for onboarding, where
            // the field starts empty. `aiKeyScreen` therefore disables its
            // consent toggle until a key has actually been typed, so it can
            // never opt in against a credential the user cannot see.
            let storedKey = (try? keyStore.key(provider: provider.keychainProvider)) ?? nil
            let hasKey = !trimmedKey.isEmpty || !(storedKey ?? "").isEmpty
            let mayOptIn: Bool
            switch provider {
            case .anthropic:
                mayOptIn = hasKey
            case .openAICompat:
                let url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                let chosenModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
                mayOptIn = !url.isEmpty && URL(string: url)?.host != nil && !chosenModel.isEmpty
            }
            let effectiveOptIn = optIn && mayOptIn

            for (feature, model) in modelsByFeature {
                try await database.setAIConfig(
                    feature: feature.rawValue, model: model, baseURL: baseEncoding,
                    optIn: effectiveOptIn, account: account)
            }
            isEnabled = effectiveOptIn
            // The banner reports what was actually written. Saying "AI
            // enabled." while persisting `opt_in = 0` would be a worse lie
            // than the one this whole change set exists to remove.
            if effectiveOptIn {
                banner = "AI enabled."
            } else if optIn {
                banner =
                    provider == .anthropic
                    ? "Add an API key to turn AI on."
                    : "Add a server URL and model to turn AI on."
            } else {
                banner = "Key saved. AI stays off until you turn it on."
            }
        } catch {
            banner = "Couldn't save settings."
        }
    }

    /// Turn AI back off (opt every feature out — the key stays in the Keychain
    /// so re-enabling doesn't require re-pasting it).
    public func disable() async {
        // Flips `opt_in` only. The previous implementation re-wrote every row
        // with `model: ""`, `baseURL: nil`, which erased the provider encoding
        // — so a user running a LOCAL model (nothing leaving the machine) who
        // toggled AI off and on again silently came back as cloud Anthropic.
        // See `revokeAIOptIn`.
        // Not `try?`. Consent lives in the DATABASE — `AIBootstrap` reads
        // `ai_config.opt_in`, never this object's `isEnabled` — so swallowing
        // a failed write here would leave every feature genuinely opted in
        // while the sheet reported the opposite. Reporting a revocation that
        // did not happen is the worst possible failure for this particular
        // control.
        do {
            try await database.revokeAIOptIn(account: account)
        } catch {
            banner = "Couldn't turn AI off — try again."
            return
        }
        isEnabled = false
        banner = "AI turned off."
    }
}
