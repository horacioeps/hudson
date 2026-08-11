import Foundation
import Synchronization

@testable import AIKit

/// A test double `LLMHTTP` that returns a scripted OUTCOME per `stream` call,
/// letting a test drive `AnthropicProvider`'s own 429 backoff without any real
/// network or timing. Each call to `stream` consumes the next outcome in order:
/// a `.failure` throws at the `try await http.stream(...)` point (exactly where
/// `URLSessionLLMHTTP` surfaces a non-2xx status, since it checks the status
/// BEFORE returning the byte stream — so a 429 is always a throw-on-open, never
/// a mid-iteration error), and a `.success` replays already-framed event
/// payloads. When the script runs dry it repeats the last outcome, so a
/// "429 forever" test can just supply a single `.failure`.
final class FlakyLLMHTTP: LLMHTTP {
    enum Outcome {
        /// `http.stream(...)` throws this before yielding any bytes.
        case failure(Error)
        /// `http.stream(...)` yields these framed `data:` payloads, in order.
        case success([Data])
    }

    private let outcomes: [Outcome]
    /// How many times `stream` has been invoked — the retry count a test asserts on.
    private let calls = Mutex(0)

    init(outcomes: [Outcome]) {
        precondition(!outcomes.isEmpty, "FlakyLLMHTTP needs at least one outcome")
        self.outcomes = outcomes
    }

    var callCount: Int { calls.withLock { $0 } }

    func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<Data, Error> {
        let outcome: Outcome = calls.withLock { count in
            let index = min(count, outcomes.count - 1)
            count += 1
            return outcomes[index]
        }
        switch outcome {
        case .failure(let error):
            throw error
        case .success(let payloads):
            return AsyncThrowingStream { continuation in
                for payload in payloads {
                    continuation.yield(payload)
                }
                continuation.finish()
            }
        }
    }
}
