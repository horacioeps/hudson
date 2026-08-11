import Foundation
import Synchronization
import Testing

@testable import AIKit

/// Tests for `AnthropicProvider` — the event-typed SSE parser + 5-series
/// request contract + refusal handling + own 429 backoff. Everything is driven
/// through `ScriptedLLMHTTP` / `FlakyLLMHTTP` fixtures, so no test ever opens a
/// socket. Backoff is injected as a no-op recorder, so the retry tests don't
/// actually sleep.
struct AnthropicProviderTests {
    /// One framed SSE `data:` payload (raw JSON bytes) — exactly what
    /// `LLMHTTP.stream` is contracted to yield after SSE framing.
    private func payload(_ json: String) -> Data { Data(json.utf8) }

    /// A normal Anthropic Messages stream: message_start (carries input tokens),
    /// two text deltas, block stop, message_delta (stop_reason end_turn + output
    /// tokens), message_stop.
    private var normalScript: [Data] {
        [
            payload(#"{"type":"message_start","message":{"usage":{"input_tokens":10,"output_tokens":1}}}"#),
            payload(#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
            payload(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#),
            payload(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}"#),
            payload(#"{"type":"content_block_stop","index":0}"#),
            payload(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}"#),
            payload(#"{"type":"message_stop"}"#),
        ]
    }

    private func makeProvider(_ http: any LLMHTTP) -> AnthropicProvider {
        // Deterministic backoff that never sleeps, so retry tests stay instant.
        AnthropicProvider(
            http: http, apiKey: "test-key",
            baseURL: URL(string: "https://api.anthropic.com")!,
            maxRetries: 3, backoff: { _ in }
        )
    }

    @Test func normalStreamYieldsOrderedTextThenUsageThenStopped() async throws {
        let provider = makeProvider(ScriptedLLMHTTP(script: normalScript))
        let events = try await collect(provider.stream(anyRequest))
        #expect(
            events == [
                .textDelta("Hello"),
                .textDelta(" world"),
                .usage(inputTokens: 10, outputTokens: 5),
                .stopped,
            ]
        )
    }

    @Test func thinkingDeltasSurfaceSeparatelyFromText() async throws {
        let script = [
            payload(#"{"type":"message_start","message":{"usage":{"input_tokens":7,"output_tokens":1}}}"#),
            payload(#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"pondering"}}"#),
            payload(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Answer"}}"#),
            payload(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}"#),
            payload(#"{"type":"message_stop"}"#),
        ]
        let provider = makeProvider(ScriptedLLMHTTP(script: script))
        let events = try await collect(provider.stream(anyRequest))
        #expect(
            events == [
                .thinkingDelta("pondering"),
                .textDelta("Answer"),
                .usage(inputTokens: 7, outputTokens: 3),
                .stopped,
            ]
        )
    }

    @Test func refusalYieldsRefusalAndNoContentOrStopped() async throws {
        // 5-series contract: stop_reason == "refusal" is handled BEFORE any
        // content — the fixture carries no text deltas, and the parser must
        // emit `.refusal` alone (never `.stopped`).
        let script = [
            payload(#"{"type":"message_start","message":{"usage":{"input_tokens":9,"output_tokens":1}}}"#),
            payload(#"{"type":"message_delta","delta":{"stop_reason":"refusal"},"usage":{"output_tokens":0}}"#),
            payload(#"{"type":"message_stop"}"#),
        ]
        let provider = makeProvider(ScriptedLLMHTTP(script: script))
        let events = try await collect(provider.stream(anyRequest))
        #expect(events == [.refusal])
    }

    @Test func requestOmitsForbiddenFieldsAndCarriesAuthHeaders() async throws {
        let http = ScriptedLLMHTTP(script: normalScript)
        let provider = makeProvider(http)
        _ = try await collect(provider.stream(anyRequest))

        let request = try #require(http.lastRequest)
        // Auth + version headers.
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")

        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        // The 5-series knobs 400 the API — they must be absent by construction.
        #expect(json["temperature"] == nil)
        #expect(json["top_p"] == nil)
        #expect(json["top_k"] == nil)
        #expect(json["budget_tokens"] == nil)
        // The portable fields that MUST be present.
        #expect(json["model"] as? String == "claude-haiku-4-5")
        #expect(json["max_tokens"] as? Int == 256)
        #expect(json["stream"] as? Bool == true)
        #expect(json["system"] as? String == "You are terse.")
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        #expect(messages[0]["content"] as? String == "Hi")
    }

    @Test func rateLimitRetriesWithBackoffThenSucceeds() async throws {
        let http = FlakyLLMHTTP(outcomes: [
            .failure(AIError.httpStatus(429)),
            .failure(AIError.httpStatus(429)),
            .success(normalScript),
        ])
        let backoffAttempts = Mutex<[Int]>([])
        let provider = AnthropicProvider(
            http: http, apiKey: "k", baseURL: URL(string: "https://api.anthropic.com")!,
            maxRetries: 3, backoff: { attempt in backoffAttempts.withLock { $0.append(attempt) } }
        )
        let events = try await collect(provider.stream(anyRequest))
        #expect(events.contains(.stopped))
        #expect(http.callCount == 3)                          // two 429s + one success
        #expect(backoffAttempts.withLock { $0 } == [0, 1])    // backoff before each retry
    }

    @Test func rateLimitBeyondMaxRetriesThrows() async throws {
        let http = FlakyLLMHTTP(outcomes: [.failure(AIError.httpStatus(429))])
        let provider = AnthropicProvider(
            http: http, apiKey: "k", baseURL: URL(string: "https://api.anthropic.com")!,
            maxRetries: 2, backoff: { _ in }
        )
        await #expect(throws: AIError.httpStatus(429)) {
            _ = try await collect(provider.stream(anyRequest))
        }
        #expect(http.callCount == 3)  // initial attempt + 2 retries
    }

    /// A non-429 HTTP error is NOT retried — AIKit owns only 429 backoff.
    @Test func nonRateLimitErrorIsNotRetried() async throws {
        let http = FlakyLLMHTTP(outcomes: [.failure(AIError.httpStatus(500))])
        let provider = makeProvider(http)
        await #expect(throws: AIError.httpStatus(500)) {
            _ = try await collect(provider.stream(anyRequest))
        }
        #expect(http.callCount == 1)  // no retry
    }

    private var anyRequest: LLMRequest {
        LLMRequest(
            model: "claude-haiku-4-5",
            system: "You are terse.",
            messages: [LLMMessage(role: .user, text: "Hi")],
            maxTokens: 256
        )
    }
}
