import Foundation

/// The four AI features Hudson exposes. Each is independently opt-in via an
/// `ai_config` row (spec §8 egress table) — turning on summarize never turns
/// on ask-inbox. The raw value is the `feature` column key used by
/// `HudsonDatabase.aiConfig(feature:account:)`, so these strings are a
/// storage contract, not just labels.
public enum AIFeature: String, Sendable {
    case summarize
    case draft
    case ask
    case voiceProfile
}

/// One turn in an LLM conversation. `text` is always PLAIN TEXT — feature
/// modules build context from message bodies' plain-text, never raw HTML
/// (spec §8 privacy stance; raw markup would both leak tracking structure and
/// waste the token budget).
public struct LLMMessage: Sendable {
    public enum Role: String, Sendable {
        case system
        case user
        case assistant
    }

    public let role: Role
    public let text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

/// A provider-agnostic streaming request. Deliberately carries ONLY the
/// fields that are portable across Anthropic and OpenAI-compatible APIs:
/// `model`, an optional `system` prompt, the `messages`, and `maxTokens`.
/// The 5-series sampling knobs (`temperature`/`top_p`/`top_k`/`budget_tokens`)
/// are absent by construction — they 400 on Opus/Sonnet/Fable 5, so there is
/// no field here through which a caller could ever set them.
public struct LLMRequest: Sendable {
    public let model: String
    public let system: String?
    public let messages: [LLMMessage]
    public let maxTokens: Int

    public init(model: String, system: String?, messages: [LLMMessage], maxTokens: Int) {
        self.model = model
        self.system = system
        self.messages = messages
        self.maxTokens = maxTokens
    }
}

/// A single event in a streamed response. `.thinkingDelta` is surfaced (not
/// dropped) so the UI can show adaptive-thinking progress without conflating
/// it with the answer; `.refusal` is its own case so callers branch on it
/// BEFORE reading any `.textDelta` (5-series `stop_reason == "refusal"`
/// arrives with no usable content).
public enum LLMEvent: Sendable, Equatable {
    case textDelta(String)
    case thinkingDelta(String)
    case usage(inputTokens: Int, outputTokens: Int)
    case refusal
    case stopped
}

/// The one streaming verb every provider implements. There is intentionally
/// no buffered/non-streaming variant: SSE first-token latency is a product
/// requirement and buffering a whole `Data` blob can't stream it (architecture
/// pillar 1). Implementations are `Sendable` structs; the returned stream is
/// consumed once by exactly one caller — `EgressGuard`.
public protocol LLMProvider: Sendable {
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error>
}
