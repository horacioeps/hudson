import Foundation
import Store

/// Drafts a reply or a new email in the user's own voice (spec §8: "Draft(reply
/// | new, instruction): uses a *voice profile*"). Egress = voice profile +
/// (current thread, if replying) + instruction — exactly the spec §8
/// egress-table row for Draft; nothing else leaves the machine.
///
/// A `struct` (value semantics): it holds only actor references
/// (`EgressGuard`) plus read-only config — no mutable state of its own to
/// protect.
public struct Draft: Sendable {
    private let egressGuard: EgressGuard
    private let voiceProfile: VoiceProfile
    private let database: HudsonDatabase
    private let account: String

    /// Architecture "M7 — AIKit": Draft's documented default.
    static let defaultModel = "claude-sonnet-5"

    /// A drafted email body is roomier than a summary's few sentences, but
    /// still bounded so a runaway completion can't blow past what a normal
    /// email looks like.
    private static let maxTokens = 2048

    private static let systemPrompt = """
        You draft email text in the described voice. You are given a style \
        card describing how this person writes, optionally the thread they are \
        replying to, and an instruction for what the draft should say. Write \
        only the drafted email body — no subject line, no commentary, and no \
        placeholder sign-off unless the voice profile shows the person actually \
        signs off that way.
        """

    public init(
        `guard`: EgressGuard, voiceProfile: VoiceProfile, database: HudsonDatabase, account: String
    ) {
        self.egressGuard = `guard`
        self.voiceProfile = voiceProfile
        self.database = database
        self.account = account
    }

    /// Drafts a reply to `replyTo` (or a new email if `nil`) following
    /// `instruction`, streaming the drafted text as it's generated.
    ///
    /// Fetches the voice profile FIRST, via its OWN `.voiceProfile`-scoped
    /// invocation (`Invocation.userInvoked(.voiceProfile)`) — a SEPARATE
    /// explicit-invocation egress from the draft's own, gated by
    /// `.voiceProfile`'s own opt-in row rather than `.draft`'s (see
    /// `VoiceProfile`'s doc comment for why: a user can opt into draft
    /// assistance without separately consenting to "read my sent mail to
    /// learn my style" until a draft actually needs it). A cached profile
    /// costs zero egress here; only a first-use or stale-corpus distillation
    /// does. The draft's own generation call is gated separately, by
    /// `invocation` (`.draft`'s opt-in), through `EgressGuard.run` — the same
    /// shape as `Summarize`.
    public func draft(
        replyTo threadID: String?, instruction: String, invocation: Invocation
    ) async throws -> AsyncThrowingStream<String, Error> {
        let profile = try await voiceProfile.current(
            invocation: .userInvoked(.voiceProfile), forceRefresh: false)

        var blocks = ["Voice profile:\n\(profile)"]
        if let threadID {
            let messages = try await database.threadMessages(threadID: threadID, account: account)
            // An unknown/vanished thread id has nothing to reply to — fail
            // fast rather than silently drafting a "reply" with no thread
            // context at all (mirrors `Summarize.emptyThread`).
            guard !messages.isEmpty else { throw AIError.emptyThread(threadID) }
            blocks.append("Thread being replied to:\n\(try await threadContext(messages))")
        }
        blocks.append("Instruction: \(instruction)")
        let context = blocks.joined(separator: "\n\n---\n\n")

        let model = try await resolvedModel()
        let request = LLMRequest(
            model: model, system: Self.systemPrompt,
            messages: [LLMMessage(role: .user, text: context)], maxTokens: Self.maxTokens)
        // The ONLY egress this method performs directly: forwards through
        // EgressGuard, which re-checks `.draft`'s own `ai_config.opt_in` for
        // `invocation.feature` before ever reaching the provider.
        let events = try await egressGuard.run(request, for: invocation)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    _ = try await forward(events, to: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Same drain-and-forward shape as `Summarize.forward`: text deltas
    /// stream live to the caller; `.refusal` (5-series `stop_reason ==
    /// "refusal"`) is branched on BEFORE reading any content and stops the
    /// drain immediately, before any further (nonexistent) content would be
    /// read.
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
                return accumulated
            case .thinkingDelta, .usage, .stopped:
                continue
            }
        }
        return accumulated
    }

    /// The configured model for `.draft`, falling back to the documented
    /// default — `ai_config` is consulted first and wins whenever a row
    /// exists; the constant is only ever a fallback, never the sole source.
    private func resolvedModel() async throws -> String {
        let config = try await database.aiConfig(feature: AIFeature.draft.rawValue, account: account)
        return config?.model ?? Self.defaultModel
    }

    /// Builds the PLAIN-TEXT thread context (spec §8: never raw HTML) — same
    /// shape as `Summarize.buildContext`, since a reply draft needs the same
    /// "what was said, by whom" view of the thread a summary does.
    private func threadContext(_ messages: [MessageRow]) async throws -> String {
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
