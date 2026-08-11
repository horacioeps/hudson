import Foundation
import Testing

@testable import AIKit

/// End-to-end tests for `URLSessionLLMHTTP.stream()` itself — the byte-driven
/// trigger/flush loop and the `URLSession` error wrapping — driven through
/// `URLSession.shared` via `StubURLProtocol`, with no real socket. Distinct
/// from `SSEFramingTests` (which exercises the pure `SSEFraming.frame`
/// function directly on byte fixtures) and from the Task 3/4 provider tests
/// (which use `ScriptedLLMHTTP`, a hand-rolled double that replays
/// already-framed events and so never touches this loop at all).
///
/// `URLProtocol.registerClass` is process-global; `onceRegistered`'s lazy
/// `static let` initialization is guaranteed atomic/run-once by the Swift
/// runtime even if two tests race to trigger it, and each test below targets
/// its own unique URL (`StubURLProtocol.uniqueStubURL()`), so concurrently
/// running tests never share mutable stub state.
private enum RegisterStub {
    static let onceRegistered: Void = {
        URLProtocol.registerClass(StubURLProtocol.self)
    }()
}

/// Builds a plain GET `URLRequest` at a fresh stub URL, registers `script`
/// for it, and returns the request ready to hand to `URLSessionLLMHTTP`.
private func stubbedRequest(_ script: StubURLProtocol.Script) -> URLRequest {
    _ = RegisterStub.onceRegistered
    let url = StubURLProtocol.uniqueStubURL()
    StubURLProtocol.stub(url, script)
    return URLRequest(url: url)
}

// MARK: - end-of-stream flush (the dropped-final-event regression)

/// THE regression this fix-loop exists for: the connection closes right
/// after a `data:` line with NO trailing blank line — no more bytes ever
/// arrive to complete the `\n\n` the in-loop trigger waits for. Pre-fix,
/// `SSEFraming.frame(buffer)` requires a literal `\n\n` to recognize a
/// block, so the post-loop flush call returned `events: []` and the whole
/// tail was discarded as `remainder` — the stream finished cleanly with the
/// last event (which could be the final text delta, the usage/stop event,
/// or a refusal) silently missing. This drives the PRODUCTION
/// `URLSessionLLMHTTP.stream()` (not just the pure framer) to prove the
/// fix holds in the actual shipped code path.
@Test func endToEndFlushesFinalEventThatHasNoTrailingBlankLine() async throws {
    let request = stubbedRequest(
        .response(status: 200, chunks: [Data("data: {\"final\":true}\n".utf8)]))

    let stream = try await URLSessionLLMHTTP().stream(request)
    var received: [Data] = []
    for try await chunk in stream {
        received.append(chunk)
    }

    #expect(received == [Data("{\"final\":true}".utf8)])
}

/// The connection can also close with NO trailing newline at all (a raw
/// truncation mid-line). The flush still fires for whatever's in the
/// buffer — this pins that `!buffer.isEmpty` still triggers a flush attempt
/// even without any newline present, rather than requiring at least one.
@Test func endToEndFlushesFinalEventWithNoTrailingNewlineAtAll() async throws {
    let request = stubbedRequest(
        .response(status: 200, chunks: [Data("data: {\"partial\":tr".utf8)]))

    let stream = try await URLSessionLLMHTTP().stream(request)
    var received: [Data] = []
    for try await chunk in stream {
        received.append(chunk)
    }

    #expect(received == [Data("{\"partial\":tr".utf8)])
}

/// A normal, well-terminated multi-event stream (every event followed by
/// its own `\n\n`) still frames every event exactly once through the
/// in-loop trigger — the flush fix must not introduce a duplicate dispatch
/// of the last event when the stream already ended cleanly.
@Test func endToEndFramesEveryEventExactlyOnceWhenStreamEndsCleanly() async throws {
    let body = "data: {\"n\":1}\n\ndata: {\"n\":2}\n\n"
    let request = stubbedRequest(.response(status: 200, chunks: [Data(body.utf8)]))

    let stream = try await URLSessionLLMHTTP().stream(request)
    var received: [Data] = []
    for try await chunk in stream {
        received.append(chunk)
    }

    #expect(received == [Data("{\"n\":1}".utf8), Data("{\"n\":2}".utf8)])
}

// MARK: - CR/LF end-to-end (through the full production seam)

/// A fully CRLF-framed event (`\r\n` line endings AND `\r\n\r\n` block
/// separator) round-trips through the real `URLSessionLLMHTTP.stream()` —
/// combining the `SSEFraming.frame` CR-stripping fix with the end-of-stream
/// flush fix, since the in-loop byte trigger (which watches for two RAW
/// `\n` bytes back to back) never fires mid-stream for a pure `\r\n\r\n`
/// separator; this event only ever reaches the wire via the post-loop
/// flush, so this test is also, incidentally, further proof the flush path
/// works.
@Test func endToEndFramesFullyCRLFTerminatedEvent() async throws {
    let body = "event: content_block_delta\r\ndata: {\"text\":\"hi\"}\r\n\r\n"
    let request = stubbedRequest(.response(status: 200, chunks: [Data(body.utf8)]))

    let stream = try await URLSessionLLMHTTP().stream(request)
    var received: [Data] = []
    for try await chunk in stream {
        received.append(chunk)
    }

    #expect(received == [Data("{\"text\":\"hi\"}".utf8)])
}

// MARK: - AIError wrapping (raw URLError never escapes untyped)

/// A transport failure before any HTTP response is ever received (DNS
/// failure, connection refused, TLS failure, timeout, ...) — the initial
/// `try await URLSession.shared.bytes(for:)` call itself throws a raw
/// `URLError`. `URLSessionLLMHTTP.stream` must rewrap it as `AIError`,
/// mirroring GmailKit's `URLSessionTransport.send`, so callers can switch
/// over `AIError` exhaustively per its own doc comment.
@Test func endToEndWrapsInitialConnectionFailureAsAIError() async throws {
    let request = stubbedRequest(.failBeforeResponse(code: .networkConnectionLost))

    do {
        _ = try await URLSessionLLMHTTP().stream(request)
        Issue.record("expected stream(_:) to throw")
    } catch let error as AIError {
        guard case .transport = error else {
            Issue.record("expected AIError.transport, got \(error)")
            return
        }
    } catch {
        Issue.record("expected an AIError, got a raw \(type(of: error)): \(error)")
    }
}

/// A transport failure mid-stream (after a response and some bytes have
/// already arrived), driven through the real `URLProtocol` stub. Whether
/// `URLSession` surfaces this at the initial `bytes(for:)` await or partway
/// through the byte-iteration loop is an OS-level timing detail this test
/// deliberately does not pin down (a `URLProtocol` double that delivers its
/// whole script synchronously in `startLoading()` can legitimately collapse
/// either way) — what must hold regardless is that NO raw `URLError` ever
/// escapes `URLSessionLLMHTTP.stream`. See
/// `midStreamByteIterationFailureIsWrappedAsAIError` below for a
/// deterministic pin of "already-framed events survive the eventual throw".
@Test func endToEndWrapsConnectionFailureAfterSomeDataAsAIError() async throws {
    let request = stubbedRequest(
        .responseThenFail(
            status: 200,
            chunks: [Data("data: {\"n\":1}\n\n".utf8)],
            code: .networkConnectionLost))

    do {
        let stream = try await URLSessionLLMHTTP().stream(request)
        for try await _ in stream {}
        Issue.record("expected a failure to surface as AIError")
    } catch let error as AIError {
        guard case .transport = error else {
            Issue.record("expected AIError.transport, got \(error)")
            return
        }
    } catch {
        Issue.record("expected an AIError, got a raw \(type(of: error)): \(error)")
    }
}

/// The deterministic version of the above: feeds real bytes then a raw
/// `URLError` directly into `URLSessionLLMHTTP.frameEvents` — the exact
/// production byte-loop, extracted specifically so this is testable without
/// depending on `URLProtocol`/`URLSession`'s own timing. Pins BOTH halves
/// of the contract precisely: the already-complete event is yielded before
/// the failure, and the failure itself is a typed `AIError`, never the raw
/// `URLError`.
@Test func midStreamByteIterationFailureIsWrappedAsAIError() async throws {
    let bytes = AsyncThrowingStream<UInt8, Error> { continuation in
        for byte in Data("data: {\"n\":1}\n\n".utf8) {
            continuation.yield(byte)
        }
        continuation.finish(throwing: URLError(.networkConnectionLost))
    }

    let stream = URLSessionLLMHTTP.frameEvents(from: bytes)
    var received: [Data] = []
    do {
        for try await chunk in stream {
            received.append(chunk)
        }
        Issue.record("expected the stream to throw after the already-framed event")
    } catch let error as AIError {
        guard case .transport = error else {
            Issue.record("expected AIError.transport, got \(error)")
            return
        }
    } catch {
        Issue.record("expected an AIError, got a raw \(type(of: error)): \(error)")
    }

    #expect(received == [Data("{\"n\":1}".utf8)])
}

// MARK: - non-2xx status still surfaces as AIError.httpStatus

/// Untouched by this fix-loop's changes, but cheap insurance that
/// extracting the byte loop into `frameEvents` didn't disturb the
/// pre-existing non-2xx handling in `stream(_:)`.
@Test func endToEndNonSuccessStatusThrowsHTTPStatusError() async throws {
    let request = stubbedRequest(.response(status: 429, chunks: []))

    do {
        _ = try await URLSessionLLMHTTP().stream(request)
        Issue.record("expected stream(_:) to throw")
    } catch let error as AIError {
        #expect(error == .httpStatus(429))
    } catch {
        Issue.record("expected AIError.httpStatus, got a raw \(type(of: error)): \(error)")
    }
}
