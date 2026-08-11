import Foundation
import Synchronization

@testable import AIKit

/// A test double `LLMProvider` that replays a fixed script of events and
/// counts how many times `stream` was called. Used to assert (a) that a
/// not-opted-in feature reaches the provider ZERO times, and (b) that an
/// opted-in feature's request is forwarded and the scripted events flow back.
/// Never hits the network.
final class ScriptedProvider: LLMProvider {
    /// The events every `stream` call replays, in order.
    private let script: [LLMEvent]
    /// Thread-safe record of calls, so tests can assert call count and inspect
    /// the exact request that was forwarded (proving EgressGuard passes it
    /// through unchanged).
    private let calls = Mutex<[LLMRequest]>([])

    init(script: [LLMEvent]) {
        self.script = script
    }

    var callCount: Int { calls.withLock { $0.count } }
    var lastRequest: LLMRequest? { calls.withLock { $0.last } }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        calls.withLock { $0.append(request) }
        let script = self.script
        return AsyncThrowingStream { continuation in
            for event in script {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}

/// Drains a stream into an array so tests can assert on the full sequence.
func collect(_ stream: AsyncThrowingStream<LLMEvent, Error>) async throws -> [LLMEvent] {
    var events: [LLMEvent] = []
    for try await event in stream {
        events.append(event)
    }
    return events
}
