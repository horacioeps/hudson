import AIKit
import Foundation
import GmailKit
import Store

/// Builds a `Summarize` from whatever `ai_config` + Keychain hold for
/// `account` — the UI-side seam `SummaryModel` runs the Summarize chip
/// through, mirroring `SendBootstrap`/`SyncBootstrap`'s "Keychain → engine"
/// shape. Fail-closed by construction: if the feature isn't opted in this
/// returns `nil` and no provider is ever built, so the chip degrades to a
/// "turn AI on" banner instead of egressing.
///
/// This duplicates a handful of lines from `HudsonCLI`'s `AIRuntime.bootstrap`
/// rather than sharing them: `HudsonUI` cannot depend on `HudsonCLI`
/// (dependencies only run executable → library, never the reverse) — the same
/// reason `SyncBootstrap`/`SendBootstrap` re-derive their own `GmailClient`
/// wiring. `hudson ai config` (CLI) stays the SOLE writer of `ai_config`, and
/// the source of truth for the `base_url` provider encoding decoded below.
enum AIBootstrap {
    /// Reads `summarize`'s `ai_config` row and, only if it is opted in,
    /// assembles the provider (`base_url` names which — see
    /// `SummarizeProviderSelection`), the stored API key
    /// (`KeychainLLMKeyStore`, keyed by provider kind), an `EgressGuard` over
    /// that provider, and the `Summarize` on top. Returns `nil` when the
    /// feature has no row or `opt_in != true` — the fail-closed default that
    /// matches `EgressGuard`'s own gate, so a not-opted-in feature can't even
    /// reach a built provider.
    ///
    /// `keyStore`/`http` default to the real Keychain/URLSession seams in
    /// production but are injectable so tests exercise the opt-in gating
    /// without touching the macOS Keychain or the network (spec §6.3, the
    /// same rule every other `LLMKeyStore` consumer follows).
    static func makeSummarize(
        database: HudsonDatabase,
        account: String,
        keyStore: any LLMKeyStore = KeychainLLMKeyStore(),
        http: any LLMHTTP = URLSessionLLMHTTP()
    ) async -> Summarize? {
        // Fail closed on ANY read failure too, not just a missing/opt-out row:
        // a Store error must never be the reason content leaks, so `try?` +
        // the `optIn` guard both have to hold before a provider is built.
        guard
            let config = try? await database.aiConfig(
                feature: AIFeature.summarize.rawValue, account: account),
            config.optIn
        else { return nil }

        let selection = SummarizeProviderSelection.decode(config.baseURL)
        // A keyless local provider (Ollama/LM Studio) is valid: an absent
        // Keychain entry degrades to "", never a thrown error — matching
        // `AIRuntime.bootstrap`'s "tolerate an empty key" contract.
        let apiKey = (try? keyStore.key(provider: selection.keychainProvider)) ?? ""
        let provider = selection.buildProvider(http: http, apiKey: apiKey)
        let egressGuard = EgressGuard(provider: provider, database: database, account: account)
        return Summarize(guard: egressGuard, database: database, account: account)
    }
}

/// Which LLM backend a stored `ai_config` row selects, decoded from the
/// `base_url` column. No AIKit feature reads `base_url`, so `hudson ai config`
/// repurposes it as an opaque `"<kind>"` / `"<kind>|<url>"` encoding of
/// "which provider, and any base-URL override" (see `AICommands`'
/// `AIProviderConfig`, the encoder). HudsonUI can't import HudsonCLI to reuse
/// that decoder (see `AIBootstrap`'s doc comment), so the read side is
/// mirrored here — deliberately lenient: anything unrecognized or hand-edited
/// falls back to `.anthropic` with no override, an inert default that can't
/// itself cause egress (the opt-in gate, not this decode, is what blocks it).
private enum SummarizeProviderSelection {
    case anthropic
    case openAICompat(baseURL: URL?)

    private static let separator: Character = "|"

    static func decode(_ raw: String?) -> SummarizeProviderSelection {
        guard let raw, !raw.isEmpty else { return .anthropic }
        let parts = raw.split(separator: Self.separator, maxSplits: 1)
        guard let kind = parts.first else { return .anthropic }
        switch String(kind) {
        case "openai-compat":
            let override = parts.count > 1 ? URL(string: String(parts[1])) : nil
            return .openAICompat(baseURL: override)
        default:
            // "anthropic" or any stale/hand-edited value — inert default.
            return .anthropic
        }
    }

    /// The `provider` key `KeychainLLMKeyStore` filed this backend's API key
    /// under (`ai config` writes it keyed by this same raw value).
    var keychainProvider: String {
        switch self {
        case .anthropic: return "anthropic"
        case .openAICompat: return "openai-compat"
        }
    }

    /// Builds the live provider. Construction is pure (no I/O — see the
    /// providers' own doc comments), so building one for a feature that turns
    /// out not to egress is harmless. `.anthropic` never honors a base-URL
    /// override (there is none to pass); `.openAICompat` uses the configured
    /// URL when present, else the provider's OpenAI default.
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
