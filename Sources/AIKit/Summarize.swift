import Foundation
import Store

/// Thread summarization — the highest-volume, latency-critical AI feature
/// (architecture "M7 — AIKit": Claude Haiku 4.5, cached; spec §8 egress
/// table: "the one thread"). Caching is content-addressed on `(thread_id,
/// last_message_id)`: re-summarizing an unchanged thread is a local
/// `ai_artifacts` read with ZERO egress, while new mail landing in the
/// thread changes `last_message_id` — which changes the cache key — forcing
/// a fresh, correct regeneration instead of silently serving a stale
/// summary.
///
/// A `struct` (value semantics): it holds only the `EgressGuard` actor
/// reference plus read-only `database`/`account` config — no mutable state
/// of its own to protect.
public struct Summarize: Sendable {
    private let egressGuard: EgressGuard
    private let database: HudsonDatabase
    private let account: String

    /// `ai_artifacts.kind` for a thread summary.
    static let kind = "summary"

    /// Cache-key component (alongside `model`): bump this on a prompt or
    /// context-building change that should force regeneration even when
    /// `(thread_id, last_message_id)` is unchanged — mirrors
    /// `Sanitizer.version`'s re-derive-on-bump convention.
    static let promptVersion = 1

    /// Architecture "M7 — AIKit": Summarize's documented default. Used only
    /// when the user has never set a model for this feature in `ai_config` —
    /// never the sole source of truth (`ai_config` wins when present).
    static let defaultModel = "claude-haiku-4-5"

    /// A thread summary is a few sentences; bounding output keeps latency and
    /// cost predictable without truncating a normal thread mid-sentence.
    private static let maxTokens = 1024

    private static let systemPrompt = """
        You summarize email threads for someone about to read them. Write a \
        concise, neutral summary (2-4 sentences) covering what the thread is \
        about, who is involved, and what — if anything — is being asked or \
        decided. Do not invent details that are not present in the thread.
        """

    public init(`guard`: EgressGuard, database: HudsonDatabase, account: String) {
        self.egressGuard = `guard`
        self.database = database
        self.account = account
    }

    /// Summarizes one thread, streaming the summary text as it's generated.
    ///
    /// Cache-first: a hit yields the cached text and returns WITHOUT ever
    /// calling `EgressGuard` — the opt-in gate lives there, so a cached
    /// re-view exercises no code path that could possibly egress (a
    /// re-view is a <50ms local read, per architecture pillar 3).
    ///
    /// A miss builds the thread's context from PLAIN TEXT only — never raw
    /// HTML (spec §8 privacy stance) — egresses via `EgressGuard.run` under
    /// the caller's `invocation` (the opt-in gate and the `notOptedIn`
    /// failure both live there), streams the live deltas back to the caller,
    /// and once the provider stream completes, caches the accumulated text
    /// with `sources` set to every message in the thread — so a later
    /// deletion of any one of them purges this summary
    /// (`AIArtifacts.purge`).
    public func summarize(
        threadID: String, invocation: Invocation
    ) async throws -> AsyncThrowingStream<String, Error> {
        let messages = try await database.threadMessages(threadID: threadID, account: account)
        guard let lastMessage = messages.last else {
            throw AIError.emptyThread(threadID)
        }

        let model = try await resolvedModel()
        let key = Self.cacheKey(threadID: threadID, lastMessageID: lastMessage.id)

        if let cached = try await database.artifact(
            kind: Self.kind, key: key, model: model, promptVersion: Self.promptVersion,
            account: account
        ) {
            return AsyncThrowingStream { continuation in
                continuation.yield(cached)
                continuation.finish()
            }
        }

        let context = try await buildContext(messages: messages)
        let request = LLMRequest(
            model: model, system: Self.systemPrompt,
            messages: [LLMMessage(role: .user, text: context)], maxTokens: Self.maxTokens)
        // The ONLY egress in this feature: forwards through EgressGuard, which
        // re-checks `ai_config.opt_in` for `invocation.feature` before ever
        // reaching the provider (throws `AIError.notOptedIn` first if absent).
        let events = try await egressGuard.run(request, for: invocation)
        let sources = messages.map(\.id)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let accumulated = try await forward(events, to: continuation)
                    // Only cache real content: a refusal (handled inside
                    // `forward`) or an otherwise-empty stream leaves nothing
                    // worth caching as "the summary".
                    if !accumulated.isEmpty {
                        try await database.putArtifact(
                            kind: Self.kind, key: key, model: model,
                            promptVersion: Self.promptVersion, content: accumulated,
                            sources: sources, account: account,
                            createdAt: Int64(Date().timeIntervalSince1970 * 1_000))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Drains the provider's event stream, forwarding text deltas to the
    /// caller live (so the caller sees the same incremental deltas the
    /// provider sent) while accumulating them for the cache write that
    /// happens after this returns. Returns "" on a refusal — the 5-series
    /// contract's `stop_reason == "refusal"` arrives with no usable content,
    /// so `.refusal` is branched on and stops the drain immediately, before
    /// any further (nonexistent) content would be read.
    private func forward(
        _ events: AsyncThrowingStream<LLMEvent, Error>,
        to continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws -> String {
        var accumulated = ""
        for try await event in events {
            switch event {
            case .textDelta(let text):
                accumulated += text
                continuation.yield(text)
            case .refusal:
                return ""
            case .thinkingDelta, .usage, .stopped:
                continue
            }
        }
        return accumulated
    }

    /// The configured model for `.summarize`, falling back to the documented
    /// default — `ai_config` is consulted first and wins whenever a row
    /// exists; the constant is only ever a fallback, never the sole source.
    private func resolvedModel() async throws -> String {
        let config = try await database.aiConfig(
            feature: AIFeature.summarize.rawValue, account: account)
        return config?.model ?? Self.defaultModel
    }

    /// `(thread_id, last_message_id)` cache key (architecture "M7 — AIKit"):
    /// new mail landing in the thread changes `lastMessageID`, which changes
    /// this key, forcing a fresh regeneration instead of serving a stale
    /// summary.
    private static func cacheKey(threadID: String, lastMessageID: String) -> String {
        "\(threadID):\(lastMessageID)"
    }

    /// Builds the PLAIN-TEXT thread context (spec §8: never raw HTML).
    /// `threadMessages` rows don't carry body text themselves (see
    /// `AIStore.swift`'s doc comment), so each message's plain text is
    /// fetched the same way `HudsonDatabase.message(id:account:)`'s other
    /// callers do. A message with no hydrated body yet (§4.4's hydration
    /// coverage caveat) contributes a placeholder rather than dropping out of
    /// the thread context silently.
    private func buildContext(messages: [MessageRow]) async throws -> String {
        var blocks: [String] = []
        for row in messages {
            let plainText = try await database.message(id: row.id, account: account)?.plainText
            blocks.append(
                "From: \(row.fromLine)\nSubject: \(row.subject)\n\n\(plainText ?? "(body not available)")"
            )
        }
        return blocks.joined(separator: "\n\n---\n\n")
    }
}
