import Foundation
import Store

/// Draft-in-voice's style source: a compact card describing how the user
/// writes, distilled once from their sent mail and reused across every draft
/// (spec §8 Draft: "uses a *voice profile* — a distilled style card generated
/// from the user's sent mail"). Distillation is its OWN explicit-invocation
/// egress, gated by `.voiceProfile`'s own `ai_config` row — separate from
/// `.draft`'s — so a user can opt into draft assistance without separately
/// consenting to "read my sent mail to learn my style" until a draft actually
/// needs it. `Draft.draft` mints that `.voiceProfile` invocation itself when
/// it calls `current(invocation:forceRefresh:)`; a caller invoking this type
/// directly (e.g. a future "refresh voice profile" CLI command) is
/// responsible for passing a `.voiceProfile`-scoped `Invocation`, exactly as
/// `Summarize`'s callers are responsible for passing a `.summarize`-scoped one.
///
/// Refresh happens ONLY on first use, on an explicit `forceRefresh` (the
/// user-visible "refresh voice profile" command), or when this call detects
/// the cached profile predates enough hydrated sent mail to trust (see
/// `minimumCorpusThreshold`) — NEVER automatically in the background (spec
/// §8 privacy stance: "No background AI egress, ever").
///
/// A `struct` (value semantics): it holds only the `EgressGuard` actor
/// reference plus read-only `database`/`account` config — no mutable state of
/// its own to protect.
public struct VoiceProfile: Sendable {
    private let egressGuard: EgressGuard
    private let database: HudsonDatabase
    private let account: String

    /// `ai_artifacts.kind` for the distilled voice profile.
    static let kind = "voice_profile"

    /// Cache-key component (alongside `model`): bump this on a prompt change
    /// that should force regeneration, mirroring `Summarize.promptVersion`.
    static let promptVersion = 1

    /// Architecture "M7 — AIKit": voice-profile distillation's documented
    /// default (same as Draft/Ask). Used only when the user has never set a
    /// model for `.voiceProfile` in `ai_config` — `ai_config` wins when present.
    static let defaultModel = "claude-sonnet-5"

    /// A style card is a handful of bullet points, not prose — bounding
    /// output keeps distillation latency and cost predictable.
    private static let maxTokens = 1024

    /// How many of the user's most recent SENT messages feed distillation.
    /// Bounded so the prompt — and the sent-mail content that egresses — stays
    /// a fixed, predictable size regardless of how many emails the account
    /// has ever sent.
    private static let corpusLimit = 200

    /// Fewer hydrated sent bodies than this and a distilled "voice" reflects
    /// too few real examples to trust. Folded into the cache key below (see
    /// `cacheKey`) per the architecture doc's "Corrections that must not be
    /// reintroduced": *"Voice-profile `source_fingerprint` folds in the
    /// hydrated-sent-body count + a minimum-corpus threshold, so a profile
    /// distilled early over mostly-NULL sent bodies invalidates as older sent
    /// mail backfills."* While the hydrated count stays under this threshold
    /// every count maps to the SAME cache key, so a still-sparse corpus (early
    /// in backfill, §4.4) doesn't force a fresh, costly regeneration on every
    /// single newly-hydrated sent message; once backfill crosses the
    /// threshold the key changes, which invalidates a thin early profile
    /// exactly once, instead of serving it forever.
    private static let minimumCorpusThreshold = 20

    private static let systemPrompt = """
        You study a person's past sent emails and distill how they write into \
        a short style card: typical greeting/sign-off, sentence length and \
        formality, common phrasing, and tone. Write the card as compact bullet \
        points a future writer could follow to sound like this person. Do not \
        quote whole sentences verbatim; describe patterns instead.
        """

    public init(`guard`: EgressGuard, database: HudsonDatabase, account: String) {
        self.egressGuard = `guard`
        self.database = database
        self.account = account
    }

    /// Returns the current voice profile, distilling and caching it first if
    /// there is no cached profile at the current fingerprint (see `cacheKey`)
    /// or `forceRefresh` is set.
    ///
    /// A hit is a local `ai_artifacts` read with ZERO egress — the opt-in gate
    /// lives in `EgressGuard`, so a cached re-view exercises no code path that
    /// could possibly egress. A miss builds the sent-mail context from PLAIN
    /// TEXT only — never raw HTML (spec §8 privacy stance) — egresses via
    /// `EgressGuard.run` under `invocation` (the opt-in gate and the
    /// `notOptedIn` failure both live there), and once the provider stream
    /// completes, caches the accumulated text with `sources = []` — a voice
    /// profile is aggregated over many sent messages, none of which alone
    /// should invalidate it (matches `AIStore.putArtifact`'s doc comment).
    public func current(invocation: Invocation, forceRefresh: Bool) async throws -> String {
        let model = try await resolvedModel()
        let sent = try await database.sentMessages(account: account, limit: Self.corpusLimit)
        let hydratedCount = sent.filter(\.hasBody).count
        let key = Self.cacheKey(account: account, hydratedCount: hydratedCount)

        if !forceRefresh,
            let cached = try await database.artifact(
                kind: Self.kind, key: key, model: model, promptVersion: Self.promptVersion,
                account: account)
        {
            return cached
        }

        let context = try await buildContext(sent: sent)
        let request = LLMRequest(
            model: model, system: Self.systemPrompt,
            messages: [LLMMessage(role: .user, text: context)], maxTokens: Self.maxTokens)
        // The ONLY egress this method performs: forwards through EgressGuard,
        // which re-checks `.voiceProfile`'s own `ai_config.opt_in` for
        // `invocation.feature` before ever reaching the provider (throws
        // `AIError.notOptedIn` first if absent).
        let events = try await egressGuard.run(request, for: invocation)
        let accumulated = try await drain(events)

        // Only cache real content: a refusal (handled inside `drain`) leaves
        // nothing worth serving as "the voice profile" on the next call.
        if !accumulated.isEmpty {
            try await database.putArtifact(
                kind: Self.kind, key: key, model: model, promptVersion: Self.promptVersion,
                content: accumulated, sources: [], account: account,
                createdAt: Int64(Date().timeIntervalSince1970 * 1_000))
        }
        return accumulated
    }

    /// Drains the provider's event stream into the accumulated style-card
    /// text. `current` returns a plain `String` (unlike `Summarize`'s live
    /// stream) since a voice profile is consumed whole by `Draft`, never
    /// rendered incrementally. Returns "" on `.refusal` — the 5-series
    /// contract's `stop_reason == "refusal"` arrives with no usable content,
    /// so `.refusal` is branched on and stops the drain immediately, before
    /// any further (nonexistent) content would be read.
    private func drain(_ events: AsyncThrowingStream<LLMEvent, Error>) async throws -> String {
        var accumulated = ""
        for try await event in events {
            switch event {
            case .textDelta(let text):
                accumulated += text
            case .refusal:
                return ""
            case .thinkingDelta, .usage, .stopped:
                continue
            }
        }
        return accumulated
    }

    /// The configured model for `.voiceProfile`, falling back to the
    /// documented default — `ai_config` is consulted first and wins whenever a
    /// row exists; the constant is only ever a fallback, never the sole source.
    private func resolvedModel() async throws -> String {
        let config = try await database.aiConfig(
            feature: AIFeature.voiceProfile.rawValue, account: account)
        return config?.model ?? Self.defaultModel
    }

    /// See `minimumCorpusThreshold`'s doc comment: folds the hydrated
    /// sent-body count into the cache key, bucketed by threshold-sized steps
    /// once past the threshold ("thin" below it) so meaningful backfill
    /// progress invalidates a too-early profile without re-egressing on every
    /// single subsequent hydration.
    private static func cacheKey(account: String, hydratedCount: Int) -> String {
        let fingerprint =
            hydratedCount < minimumCorpusThreshold
            ? "thin" : String(hydratedCount / minimumCorpusThreshold)
        return "\(account):\(fingerprint)"
    }

    /// Builds the PLAIN-TEXT sent-mail corpus (spec §8: never raw HTML).
    /// Unlike `Summarize.buildContext` (where every thread message's absence
    /// must stay visible), an unhydrated sent message contributes nothing
    /// rather than a placeholder — a style card benefits only from real
    /// written examples, and `hydratedCount`/`cacheKey` already account for
    /// how many of them exist.
    private func buildContext(sent: [MessageRow]) async throws -> String {
        var blocks: [String] = []
        for row in sent where row.hasBody {
            guard let plainText = try await database.message(id: row.id, account: account)?.plainText,
                !plainText.isEmpty
            else { continue }
            blocks.append(plainText)
        }
        return blocks.joined(separator: "\n\n---\n\n")
    }
}
