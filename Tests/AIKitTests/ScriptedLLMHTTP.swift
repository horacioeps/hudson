import Foundation
import Synchronization

@testable import AIKit

/// A test double `LLMHTTP` that replays a fixed script of already-framed
/// event payloads (raw JSON `Data`, one element per SSE event — exactly what
/// `LLMHTTP.stream` is contracted to yield after `URLSessionLLMHTTP` has done
/// its SSE framing). Lets `AnthropicProvider`/`OpenAICompatProvider` tests
/// (Task 3/4) exercise event-type parsing and the 5-series request contract
/// without any real SSE bytes or network I/O. Also records every request it
/// was asked to stream, so tests can assert on headers/body (e.g. "the
/// forbidden 5-series fields are absent").
final class ScriptedLLMHTTP: LLMHTTP {
    /// The `Data` chunks every `stream` call replays, in order.
    private let script: [Data]
    /// Thread-safe record of calls, mirroring `ScriptedProvider`'s call log.
    private let calls = Mutex<[URLRequest]>([])

    init(script: [Data]) {
        self.script = script
    }

    var callCount: Int { calls.withLock { $0.count } }
    var lastRequest: URLRequest? { calls.withLock { $0.last } }

    func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<Data, Error> {
        calls.withLock { $0.append(request) }
        let script = self.script
        return AsyncThrowingStream { continuation in
            for chunk in script {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}
