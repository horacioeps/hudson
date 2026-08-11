import AIKit
import Foundation
import GmailKit
import Store

/// Builds AIKit features from whatever `ai_config` + Keychain hold for
/// `account` — the UI-side seam the Summarize chip / composer Draft button run
/// through, mirroring `SendBootstrap`/`SyncBootstrap`'s "Keychain → engine"
/// shape. Fail-closed by construction: if a feature isn't opted in this returns
/// `nil` and no provider is ever built, so the surface degrades to a "turn AI
/// on" affordance instead of egressing.
///
/// Duplicates a few lines of `HudsonCLI`'s wiring rather than sharing them:
/// `HudsonUI` can't depend on `HudsonCLI` (dependencies run executable →
/// library, never the reverse). The `base_url` provider encoding decoded below
/// mirrors what `hudson ai config` writes.
enum AIBootstrap {
    /// The summarize chip's engine — nil unless `.summarize` is opted in.
    static func makeSummarize(
        database: HudsonDatabase, account: String,
        keyStore: any LLMKeyStore = KeychainLLMKeyStore(),
        http: any LLMHTTP = URLSessionLLMHTTP()
    ) async -> Summarize? {
        guard
            let egressGuard = await makeEgressGuard(
                feature: .summarize,
                database: database, account: account, keyStore: keyStore, http: http)
        else { return nil }
        return Summarize(guard: egressGuard, database: database, account: account)
    }

    /// The composer's Draft-in-voice engine — nil unless `.draft` is opted in.
    /// The returned `EgressGuard` also serves the draft's own `.voiceProfile`
    /// sub-invocation (each `EgressGuard.run` checks the invocation's OWN
    /// feature opt-in), so `.voiceProfile` must be opted in too — the Settings
    /// sheet opts both in together. The voice profile is distilled from the
    /// user's SENT mail, so drafts read the way they actually write.
    static func makeDraft(
        database: HudsonDatabase, account: String,
        keyStore: any LLMKeyStore = KeychainLLMKeyStore(),
        http: any LLMHTTP = URLSessionLLMHTTP()
    ) async -> Draft? {
        guard
            let egressGuard = await makeEgressGuard(
                feature: .draft, database: database, account: account, keyStore: keyStore, http: http)
        else { return nil }
        let voiceProfile = VoiceProfile(guard: egressGuard, database: database, account: account)
        return Draft(
            guard: egressGuard, voiceProfile: voiceProfile, database: database, account: account)
    }

    /// Reads `feature`'s `ai_config` row and, only if opted in, assembles the
    /// provider (`base_url` names which — see `ProviderSelection`), the stored
    /// key (`LLMKeyStore`, keyed by provider kind), and an `EgressGuard` over
    /// it. `nil` on a missing row, `opt_in != true`, OR any read failure —
    /// fail-closed so a Store error can never be the reason content leaks.
    private static func makeEgressGuard(
        feature: AIFeature, database: HudsonDatabase, account: String,
        keyStore: any LLMKeyStore, http: any LLMHTTP
    ) async -> EgressGuard? {
        guard
            let config = try? await database.aiConfig(feature: feature.rawValue, account: account),
            config.optIn
        else { return nil }
        let selection = ProviderSelection.decode(config.baseURL)
        // A keyless local provider (Ollama/LM Studio) is valid: an absent
        // Keychain entry degrades to "", never a thrown error.
        let apiKey = (try? keyStore.key(provider: selection.keychainProvider)) ?? ""
        let provider = selection.buildProvider(http: http, apiKey: apiKey)
        return EgressGuard(provider: provider, database: database, account: account)
    }
}

/// Which LLM backend a stored `ai_config` row selects, decoded from the
/// `base_url` column (`"anthropic"` / `"openai-compat"` / `"openai-compat|<url>"`
/// — the encoding `hudson ai config` and `SettingsModel` both write). Lenient:
/// anything unrecognized falls back to `.anthropic`, an inert default that
/// can't itself cause egress (the opt-in gate, not this decode, blocks that).
private enum ProviderSelection {
    case anthropic
    case openAICompat(baseURL: URL?)

    private static let separator: Character = "|"

    static func decode(_ raw: String?) -> ProviderSelection {
        guard let raw, !raw.isEmpty else { return .anthropic }
        let parts = raw.split(separator: Self.separator, maxSplits: 1)
        guard let kind = parts.first else { return .anthropic }
        switch String(kind) {
        case "openai-compat":
            let override = parts.count > 1 ? URL(string: String(parts[1])) : nil
            return .openAICompat(baseURL: override)
        default:
            return .anthropic
        }
    }

    var keychainProvider: String {
        switch self {
        case .anthropic: return "anthropic"
        case .openAICompat: return "openai-compat"
        }
    }

    func buildProvider(http: any LLMHTTP, apiKey: String) -> any LLMProvider {
        switch self {
        case .anthropic:
            return AnthropicProvider(http: http, apiKey: apiKey)
        case .openAICompat(let baseURL):
            guard let baseURL else { return OpenAICompatProvider(http: http, apiKey: apiKey) }
            return OpenAICompatProvider(http: http, apiKey: apiKey, baseURL: baseURL)
        }
    }
}
