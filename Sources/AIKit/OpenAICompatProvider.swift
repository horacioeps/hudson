import Foundation

/// An `LLMProvider` for the OpenAI **chat-completions** streaming contract, the
/// lingua franca that OpenAI, OpenRouter, and the local runtimes **Ollama** and
/// **LM Studio** all speak. The `baseURL` is configurable precisely so all four
/// work out of the box: point it at `https://api.openai.com/v1`,
/// `https://openrouter.ai/api/v1`, `http://localhost:11434/v1` (Ollama), or
/// `http://localhost:1234/v1` (LM Studio) and the same code path serves them.
///
/// Like `AnthropicProvider`, it egresses only through the injected `LLMHTTP`
/// byte seam (never `URLSession` directly), builds a **5-series-safe** body
/// (no `temperature`/`top_p`/`top_k`/`budget_tokens` — there is no field here
/// through which a caller could set them), and owns AIKit's own 429 backoff.
///
/// A `struct` (value semantics, `Sendable`): it holds only immutable config and
/// the `http` seam; the per-request stream is built fresh each call, so there is
/// no mutable network-driven state to protect here — that lives behind
/// `EgressGuard`, the SOLE caller of `stream`.
public struct OpenAICompatProvider: LLMProvider {
    private let http: any LLMHTTP
    private let apiKey: String
    private let baseURL: URL
    /// How many times a 429 is retried before the error is surfaced.
    private let maxRetries: Int
    /// Called before each retry with the zero-based attempt index; injected (not
    /// a hard-coded `Task.sleep`) so tests exercise the retry loop instantly.
    private let backoff: @Sendable (Int) async throws -> Void

    public init(
        http: any LLMHTTP,
        apiKey: String,
        baseURL: URL = URL(string: "https://api.openai.com/v1")!
    ) {
        // Default exponential backoff: 0.5s, 1s, 2s, ... We cannot honor a
        // server `Retry-After` here because `LLMHTTP` collapses a non-2xx
        // response to `AIError.httpStatus(Int)` with no headers, so a bounded
        // exponential schedule is the best a pure byte seam allows. Mirrors
        // `AnthropicProvider`'s backoff so both providers behave identically.
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

    /// The wire body carries ONLY the portable, 5-series-safe fields. The
    /// sampling knobs are absent by construction — there is no property here
    /// through which a caller could set them, which keeps "can't 400 on a
    /// forbidden field" a structural property, not a runtime check. `usage` is
    /// requested opportunistically (see below), so no `stream_options` field is
    /// sent — that maximizes compatibility across the four supported servers.
    private struct WireRequest: Encodable {
        let model: String
        let messages: [WireMessage]
        let maxTokens: Int
        let stream: Bool
    }

    private struct WireMessage: Encodable {
        let role: String
        let content: String
    }

    private func buildRequest(_ request: LLMRequest) throws -> URLRequest {
        // Unlike Anthropic (top-level `system` field), OpenAI chat-completions
        // carries the system prompt as the FIRST `system`-role message. We
        // prepend it when present; a nil system prompt means the conversation
        // messages are sent verbatim.
        var wireMessages: [WireMessage] = []
        if let system = request.system {
            wireMessages.append(WireMessage(role: "system", content: system))
        }
        wireMessages.append(
            contentsOf: request.messages.map { WireMessage(role: $0.role.rawValue, content: $0.text) }
        )

        let wire = WireRequest(
            model: request.model,
            messages: wireMessages,
            maxTokens: request.maxTokens,
            stream: true
        )

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase  // maxTokens -> max_tokens
        let body = try encoder.encode(wire)

        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        // Local providers (Ollama/LM Studio) take NO key. Omit the header
        // entirely when the key is empty rather than sending `Bearer ` with an
        // empty token — a malformed bearer some servers reject. When present,
        // the key comes from LLMKeyStore (Keychain) and is NEVER logged.
        if !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return urlRequest
    }

    // MARK: - 429 backoff

    /// Opens the byte stream, retrying ONLY on `429`. Every other status is
    /// surfaced immediately. `URLSessionLLMHTTP` validates the status BEFORE
    /// returning the byte stream, so a 429 always throws here at the open point
    /// — never mid-iteration — which is why retrying the open call is the right
    /// and only place backoff belongs.
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

    // MARK: - SSE data-chunk parsing

    private struct ChatChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?
                /// OpenAI's structured refusal surfaces here (5-series contract).
                let refusal: String?
            }
            let delta: Delta?
            let finishReason: String?
        }
        struct Usage: Decodable {
            let promptTokens: Int?
            let completionTokens: Int?
        }
        let choices: [Choice]?
        let usage: Usage?
    }

    /// The `[DONE]` sentinel that OpenAI/OpenRouter/Ollama/LM Studio all send as
    /// the terminal SSE `data:` line — it is a literal, NOT JSON, so it is
    /// matched as a string before any decode is attempted.
    private static let doneSentinel = "[DONE]"

    /// Consumes the framed `data:` payloads and emits `LLMEvent`s in order.
    /// Each payload is one chat-completion chunk (`choices[].delta.content`),
    /// except the terminal `[DONE]` sentinel which maps to `.stopped`. `usage`
    /// is parsed whenever a chunk carries it — OpenAI proper only sends it with
    /// `stream_options.include_usage`, but OpenRouter and Ollama include it on
    /// the final chunk unprompted, so we surface it opportunistically.
    private func parse(
        _ payloads: AsyncThrowingStream<Data, Error>,
        into continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation
    ) async throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        for try await payload in payloads {
            // The `[DONE]` line is a literal sentinel, not JSON — match it
            // first so a decode is never attempted on it.
            let text = String(decoding: payload, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if text == Self.doneSentinel {
                continuation.yield(.stopped)
                return
            }

            let chunk = try decoder.decode(ChatChunk.self, from: payload)

            for choice in chunk.choices ?? [] {
                // 5-series contract: branch on refusal BEFORE any content — a
                // refused turn carries no usable answer, so emit `.refusal`
                // alone and end the stream (never `.stopped`).
                if let refusal = choice.delta?.refusal, !refusal.isEmpty {
                    continuation.yield(.refusal)
                    return
                }
                if choice.finishReason == "content_filter" {
                    continuation.yield(.refusal)
                    return
                }
                // Suppress empty-content deltas: some gateways open the stream
                // with a role-only chunk carrying `content: ""`, which is not a
                // real token — callers should see only actual text.
                if let content = choice.delta?.content, !content.isEmpty {
                    continuation.yield(.textDelta(content))
                }
            }

            // Emit usage AFTER any content in the same chunk so callers observe
            // deltas-then-usage ordering (matching AnthropicProvider), whether
            // usage rides on the finish chunk (Ollama) or a trailing
            // empty-choices chunk (OpenAI/OpenRouter).
            if let usage = chunk.usage {
                continuation.yield(
                    .usage(
                        inputTokens: usage.promptTokens ?? 0,
                        outputTokens: usage.completionTokens ?? 0
                    )
                )
            }
        }
    }
}
