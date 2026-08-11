import Foundation

/// An `LLMProvider` for Anthropic's Messages API, speaking the streaming SSE
/// (`stream: true`) contract. It egresses only through the injected `LLMHTTP`
/// byte seam — never `URLSession` directly — so tests replay fixtures with no
/// network. It is the layer that (a) builds a **5-series-safe** request body,
/// (b) turns event-typed SSE payloads into `LLMEvent`s, and (c) owns AIKit's
/// own 429 backoff (Gmail's QuotaBucket does not cover the LLM path).
///
/// A `struct` (value semantics, `Sendable`): it holds only immutable config and
/// the `http` seam, and the per-request stream is built fresh each call — there
/// is no mutable network-driven state here to protect (that lives behind
/// `EgressGuard`, the actor that is the SOLE caller of `stream`).
public struct AnthropicProvider: LLMProvider {
    private let http: any LLMHTTP
    private let apiKey: String
    private let baseURL: URL
    /// How many times a 429 is retried before the error is surfaced.
    private let maxRetries: Int
    /// Called before each retry with the zero-based attempt index; the delay is
    /// injected (not hard-coded `Task.sleep`) so tests exercise the retry loop
    /// without waiting real seconds.
    private let backoff: @Sendable (Int) async throws -> Void

    /// Anthropic pins request compatibility to a dated API version; this is the
    /// version the 5-series streaming contract was verified against.
    private static let anthropicVersion = "2023-06-01"

    public init(
        http: any LLMHTTP,
        apiKey: String,
        baseURL: URL = URL(string: "https://api.anthropic.com")!
    ) {
        // Default exponential backoff: 0.5s, 1s, 2s, ... We cannot honor a
        // server `Retry-After` here because `LLMHTTP` collapses a non-2xx
        // response to `AIError.httpStatus(Int)` with no headers, so a bounded
        // exponential schedule is the best a pure byte seam allows.
        self.init(http: http, apiKey: apiKey, baseURL: baseURL, maxRetries: 3) { attempt in
            let seconds = 0.5 * pow(2.0, Double(attempt))
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }

    /// Test/injection init: lets a test pin `maxRetries` and swap in a no-op
    /// `backoff` recorder so the 429 path runs instantly and deterministically.
    init(
        http: any LLMHTTP,
        apiKey: String,
        baseURL: URL,
        maxRetries: Int,
        backoff: @escaping @Sendable (Int) async throws -> Void
    ) {
        self.http = http
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.maxRetries = maxRetries
        self.backoff = backoff
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try buildRequest(request)
                    let payloads = try await openWithRetry(urlRequest)
                    try await parse(payloads, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Request building

    /// The wire body deliberately carries ONLY the portable, 5-series-safe
    /// fields. `temperature`/`top_p`/`top_k`/`budget_tokens` are absent by
    /// construction — there is no property here through which a caller could
    /// set them, which is what keeps "the request can't 400 on a forbidden
    /// field" a structural property rather than a runtime check.
    private struct WireRequest: Encodable {
        let model: String
        // Synthesized Encodable uses `encodeIfPresent` for optionals, so a nil
        // system prompt is OMITTED (not sent as `null`).
        let system: String?
        let messages: [WireMessage]
        let maxTokens: Int
        let stream: Bool
    }

    private struct WireMessage: Encodable {
        let role: String
        let content: String
    }

    private func buildRequest(_ request: LLMRequest) throws -> URLRequest {
        // System context belongs in `request.system` (Anthropic's top-level
        // `system` field), never as a `system`-role turn in `messages` (the API
        // rejects that). We forward each turn's role verbatim; feature modules
        // build user/assistant turns only.
        let wire = WireRequest(
            model: request.model,
            system: request.system,
            messages: request.messages.map { WireMessage(role: $0.role.rawValue, content: $0.text) },
            maxTokens: request.maxTokens,
            stream: true
        )

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase  // maxTokens -> max_tokens
        let body = try encoder.encode(wire)

        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        // The key comes from LLMKeyStore (Keychain) via the caller; it is set on
        // the request and NEVER logged (spec §9.1 never-log list).
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        return urlRequest
    }

    // MARK: - 429 backoff

    /// Opens the byte stream, retrying ONLY on `429` (rate limit). Every other
    /// status is surfaced immediately. `URLSessionLLMHTTP` validates the status
    /// BEFORE returning the byte stream, so a 429 always throws here at the open
    /// point — never mid-iteration — which is exactly why retrying the open call
    /// is the correct and only place backoff belongs.
    private func openWithRetry(_ urlRequest: URLRequest) async throws -> AsyncThrowingStream<Data, Error> {
        var attempt = 0
        while true {
            do {
                return try await http.stream(urlRequest)
            } catch AIError.httpStatus(429) {
                guard attempt < maxRetries else { throw AIError.httpStatus(429) }
                try await backoff(attempt)
                attempt += 1
            }
        }
    }

    // MARK: - SSE event parsing

    private struct EventEnvelope: Decodable { let type: String }

    private struct MessageStartEvent: Decodable {
        struct Message: Decodable { let usage: Usage? }
        struct Usage: Decodable { let inputTokens: Int? }
        let message: Message
    }

    private struct ContentBlockDeltaEvent: Decodable {
        struct Delta: Decodable {
            let type: String
            let text: String?
            let thinking: String?
        }
        let delta: Delta
    }

    private struct MessageDeltaEvent: Decodable {
        struct Delta: Decodable { let stopReason: String? }
        struct Usage: Decodable { let outputTokens: Int? }
        let delta: Delta
        let usage: Usage?
    }

    /// Consumes the framed `data:` payloads and emits `LLMEvent`s in order.
    /// Input tokens arrive only in `message_start`; output tokens only in the
    /// final `message_delta` — so we carry the input count forward and emit one
    /// combined `.usage` when the delta lands.
    private func parse(
        _ payloads: AsyncThrowingStream<Data, Error>,
        into continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation
    ) async throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var inputTokens = 0

        for try await payload in payloads {
            let envelope = try decoder.decode(EventEnvelope.self, from: payload)
            switch envelope.type {
            case "message_start":
                let event = try decoder.decode(MessageStartEvent.self, from: payload)
                inputTokens = event.message.usage?.inputTokens ?? 0

            case "content_block_delta":
                let event = try decoder.decode(ContentBlockDeltaEvent.self, from: payload)
                switch event.delta.type {
                case "text_delta":
                    if let text = event.delta.text { continuation.yield(.textDelta(text)) }
                case "thinking_delta":
                    // Surfaced (not dropped) so the UI can show adaptive-thinking
                    // progress without conflating it with the answer.
                    if let thinking = event.delta.thinking { continuation.yield(.thinkingDelta(thinking)) }
                default:
                    break  // other block delta kinds carry nothing we model
                }

            case "message_delta":
                let event = try decoder.decode(MessageDeltaEvent.self, from: payload)
                // 5-series contract: branch on refusal BEFORE surfacing usage or
                // waiting for a stop — a refused turn arrives with no usable
                // content, so we emit `.refusal` alone and end the stream.
                if event.delta.stopReason == "refusal" {
                    continuation.yield(.refusal)
                    return
                }
                continuation.yield(.usage(inputTokens: inputTokens, outputTokens: event.usage?.outputTokens ?? 0))

            case "message_stop":
                continuation.yield(.stopped)
                return

            default:
                break  // ping / content_block_start / content_block_stop: no event
            }
        }
    }
}
