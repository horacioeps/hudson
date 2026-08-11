import Foundation
import Synchronization
import Testing

@testable import AIKit

/// Tests for `OpenAICompatProvider` — the data-chunk (`choices[].delta.content`)
/// SSE parser, `[DONE]` sentinel, opportunistic `usage`, base-URL routing (so
/// OpenAI / OpenRouter / Ollama / LM Studio all work), empty-key tolerance for
/// local providers, and the shared 5-series request contract + 429 backoff.
/// Everything runs through `ScriptedLLMHTTP` / `FlakyLLMHTTP` fixtures, so no
/// test opens a socket, and backoff is a no-op recorder so retries stay instant.
struct OpenAICompatProviderTests {
    private func payload(_ text: String) -> Data { Data(text.utf8) }

    /// A normal OpenAI-style chat-completions stream: an opening role-only chunk
    /// (empty `content` that must be suppressed), two content deltas, a
    /// finish-reason chunk with no content, a usage-only chunk (empty
    /// `choices`), then the `[DONE]` sentinel.
    private var openAIScript: [Data] {
        [
            payload(#"{"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}"#),
            payload(#"{"choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}"#),
            payload(#"{"choices":[{"index":0,"delta":{"content":" world"},"finish_reason":null}]}"#),
            payload(#"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#),
            payload(#"{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}"#),
            payload("[DONE]"),
        ]
    }

    /// An Ollama-style stream (LM Studio matches): usage rides on the FINAL
    /// content chunk alongside a `finish_reason` (not a separate empty-choices
    /// chunk), then `[DONE]`. Proves usage is parsed regardless of which chunk
    /// carries it.
    private var ollamaScript: [Data] {
        [
            payload(#"{"id":"chatcmpl-x","object":"chat.completion.chunk","model":"llama3","choices":[{"index":0,"delta":{"role":"assistant","content":"Hi"},"finish_reason":null}]}"#),
            payload(#"{"choices":[{"index":0,"delta":{"content":" there"},"finish_reason":null}]}"#),
            payload(#"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":8,"completion_tokens":4,"total_tokens":12}}"#),
            payload("[DONE]"),
        ]
    }

    private func makeProvider(
        _ http: any LLMHTTP,
        apiKey: String = "sk-test",
        baseURL: URL = URL(string: "https://api.openai.com/v1")!
    ) -> OpenAICompatProvider {
        // No-op backoff so the 429 retry test stays instant.
        OpenAICompatProvider(
            http: http, apiKey: apiKey, baseURL: baseURL,
            maxRetries: 3, backoff: { _ in }
        )
    }

    @Test func openAIStreamYieldsOrderedTextThenUsageThenStopped() async throws {
        let provider = makeProvider(ScriptedLLMHTTP(script: openAIScript))
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

    @Test func ollamaStreamParsesUsageRidingOnFinishChunk() async throws {
        let provider = makeProvider(
            ScriptedLLMHTTP(script: ollamaScript),
            apiKey: "",  // local provider needs no key
            baseURL: URL(string: "http://localhost:11434/v1")!
        )
        let events = try await collect(provider.stream(anyRequest))
        #expect(
            events == [
                .textDelta("Hi"),
                .textDelta(" there"),
                .usage(inputTokens: 8, outputTokens: 4),
                .stopped,
            ]
        )
    }

    @Test func refusalYieldsRefusalAndNoContentOrStopped() async throws {
        // 5-series contract: a refusal is surfaced BEFORE any content. OpenAI's
        // structured refusal arrives as `delta.refusal`; the parser must emit
        // `.refusal` alone and end (no `.stopped`).
        let script = [
            payload(#"{"choices":[{"index":0,"delta":{"refusal":"I can't help with that."},"finish_reason":null}]}"#),
            payload(#"{"choices":[{"index":0,"delta":{},"finish_reason":"content_filter"}]}"#),
            payload("[DONE]"),
        ]
        let provider = makeProvider(ScriptedLLMHTTP(script: script))
        let events = try await collect(provider.stream(anyRequest))
        #expect(events == [.refusal])
    }

    @Test func baseURLRoutesToConfiguredHostChatCompletions() async throws {
        // OpenAI default host.
        let openAI = ScriptedLLMHTTP(script: openAIScript)
        _ = try await collect(makeProvider(openAI).stream(anyRequest))
        #expect(
            try #require(openAI.lastRequest).url?.absoluteString
                == "https://api.openai.com/v1/chat/completions"
        )

        // Ollama's local OpenAI-compatible endpoint.
        let ollama = ScriptedLLMHTTP(script: ollamaScript)
        _ = try await collect(
            makeProvider(ollama, apiKey: "", baseURL: URL(string: "http://localhost:11434/v1")!)
                .stream(anyRequest)
        )
        #expect(
            try #require(ollama.lastRequest).url?.absoluteString
                == "http://localhost:11434/v1/chat/completions"
        )
    }

    @Test func emptyKeyOmitsAuthHeaderNonEmptyKeySendsBearer() async throws {
        // Local providers (Ollama/LM Studio) take no key — the Authorization
        // header must be ABSENT, not `Bearer ` with an empty token (some
        // servers reject a malformed bearer).
        let local = ScriptedLLMHTTP(script: openAIScript)
        _ = try await collect(makeProvider(local, apiKey: "").stream(anyRequest))
        #expect(try #require(local.lastRequest).value(forHTTPHeaderField: "Authorization") == nil)

        // A real key is sent as a bearer token.
        let cloud = ScriptedLLMHTTP(script: openAIScript)
        _ = try await collect(makeProvider(cloud, apiKey: "sk-live-123").stream(anyRequest))
        #expect(
            try #require(cloud.lastRequest).value(forHTTPHeaderField: "Authorization")
                == "Bearer sk-live-123"
        )
    }

    @Test func requestOmitsForbiddenFieldsAndMapsSystemAsFirstMessage() async throws {
        let http = ScriptedLLMHTTP(script: openAIScript)
        _ = try await collect(makeProvider(http).stream(anyRequest))

        let request = try #require(http.lastRequest)
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")

        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        // 5-series knobs 400 the API — absent by construction.
        #expect(json["temperature"] == nil)
        #expect(json["top_p"] == nil)
        #expect(json["top_k"] == nil)
        #expect(json["budget_tokens"] == nil)
        // Portable fields present.
        #expect(json["model"] as? String == "gpt-5")
        #expect(json["max_tokens"] as? Int == 256)
        #expect(json["stream"] as? Bool == true)
        // OpenAI carries the system prompt as the FIRST `system`-role message,
        // not a top-level field (unlike Anthropic).
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == "You are terse.")
        #expect(messages[1]["role"] as? String == "user")
        #expect(messages[1]["content"] as? String == "Hi")
    }

    @Test func nilSystemSendsOnlyTheConversationMessages() async throws {
        let http = ScriptedLLMHTTP(script: openAIScript)
        let request = LLMRequest(
            model: "gpt-5", system: nil,
            messages: [LLMMessage(role: .user, text: "Hi")], maxTokens: 256
        )
        _ = try await collect(makeProvider(http).stream(request))
        let sent = try #require(http.lastRequest)
        let body = try #require(sent.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
    }

    @Test func rateLimitRetriesWithBackoffThenSucceeds() async throws {
        let http = FlakyLLMHTTP(outcomes: [
            .failure(AIError.httpStatus(429)),
            .success(openAIScript),
        ])
        let backoffAttempts = Mutex<[Int]>([])
        let provider = OpenAICompatProvider(
            http: http, apiKey: "k", baseURL: URL(string: "https://api.openai.com/v1")!,
            maxRetries: 3, backoff: { attempt in backoffAttempts.withLock { $0.append(attempt) } }
        )
        let events = try await collect(provider.stream(anyRequest))
        #expect(events.contains(.stopped))
        #expect(http.callCount == 2)                       // one 429 + one success
        #expect(backoffAttempts.withLock { $0 } == [0])    // backoff before the retry
    }

    @Test func nonRateLimitErrorIsNotRetried() async throws {
        let http = FlakyLLMHTTP(outcomes: [.failure(AIError.httpStatus(500))])
        let provider = makeProvider(http)
        await #expect(throws: AIError.httpStatus(500)) {
            _ = try await collect(provider.stream(anyRequest))
        }
        #expect(http.callCount == 1)
    }

    private var anyRequest: LLMRequest {
        LLMRequest(
            model: "gpt-5",
            system: "You are terse.",
            messages: [LLMMessage(role: .user, text: "Hi")],
            maxTokens: 256
        )
    }
}
