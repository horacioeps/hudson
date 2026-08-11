import Foundation
import Synchronization

@testable import AIKit

/// A test double `LLMProvider` that replays a fixed script of events and
/// counts how many times `stream` was called. Used to assert (a) that a
/// not-opted-in feature reaches the provider ZERO times, and (b) that an
/// opted-in feature's request is forwarded and the scripted events flow back.
/// Never hits the network.
final class ScriptedProvider: LLMProvider {
    /// The events each `stream` call replays, indexed by call number
    /// (0-based). Once exhausted, the LAST script repeats for every further
    /// call — so a caller only has to spell out as many distinct responses as
    /// hops that actually need to differ, and a single-script provider (the
    /// common case) just repeats that one script forever.
    private let scripts: [[LLMEvent]]
    /// Thread-safe record of calls, so tests can assert call count and inspect
    /// the exact request that was forwarded (proving EgressGuard passes it
    /// through unchanged).
    private let calls = Mutex<[LLMRequest]>([])

    /// Replays `script` for every call — the common single-hop case.
    convenience init(script: [LLMEvent]) {
        self.init(scripts: [script])
    }

    /// Replays `scripts[n]` for the (0-indexed) nth call — a real multi-hop
    /// feature (e.g. `AskInbox`'s expansion hop followed by its answer hop)
    /// never gets byte-identical text back for both hops, so a test that
    /// needs the second hop's retrieval/behavior to depend on the FIRST hop's
    /// (distinct) output needs this instead of the single-script convenience,
    /// which would silently make both hops reply with the same text.
    init(scripts: [[LLMEvent]]) {
        precondition(!scripts.isEmpty, "ScriptedProvider needs at least one script")
        self.scripts = scripts
    }

    var callCount: Int { calls.withLock { $0.count } }
    var lastRequest: LLMRequest? { calls.withLock { $0.last } }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        let index = calls.withLock { calls in
            calls.append(request)
            return calls.count - 1
        }
        let script = scripts[min(index, scripts.count - 1)]
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
