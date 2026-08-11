import Foundation
import Synchronization

/// A `URLProtocol` stub that lets tests drive the PRODUCTION
/// `URLSessionLLMHTTP.stream()` end-to-end through `URLSession.shared` —
/// including the real initial `bytes(for:)` call and the byte-iteration
/// loop it feeds — without any real socket. `ScriptedLLMHTTP` (the
/// hand-rolled `LLMHTTP` double used by Task 3/4's provider tests) replays
/// already-framed events and so never exercises this loop; this double
/// exists specifically to close that gap.
///
/// Registered once, process-wide, via `URLProtocol.registerClass`; scoped to
/// a reserved test-only host (`stub.aikit.test`) via `canInit(with:)` so it
/// can never intercept a request anywhere else in the process (there are
/// none — AIKit's own privacy invariant means no code path egresses outside
/// `EgressGuard`, and nothing here goes near it). Each test registers its
/// script under its own unique URL from `uniqueStubURL()`, so tests running
/// concurrently never share mutable state or collide on the same slot.
final class StubURLProtocol: URLProtocol {
    enum Script: Sendable {
        /// Deliver an HTTP response with `status`, then `chunks` (each one
        /// a separate `didLoad` call, simulating distinct network reads),
        /// then finish successfully.
        case response(status: Int, chunks: [Data])
        /// Deliver a response and some chunks, then fail — simulating a
        /// connection that drops mid-stream (reset, timeout, ...).
        case responseThenFail(status: Int, chunks: [Data], code: URLError.Code)
        /// Fail before any response is ever received — simulating a
        /// connection that never establishes (DNS, TLS, refused, timeout).
        case failBeforeResponse(code: URLError.Code)
    }

    private static let scripts = Mutex<[URL: Script]>([:])

    /// Registers `script` to run the next (and only) time `url` is
    /// requested. Call before issuing the request.
    static func stub(_ url: URL, _ script: Script) {
        scripts.withLock { $0[url] = script }
    }

    /// A fresh URL under the reserved stub host, unique per call, so
    /// concurrently-running tests never share a script slot.
    static func uniqueStubURL() -> URL {
        URL(string: "https://stub.aikit.test/\(UUID().uuidString)")!
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "stub.aikit.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let script = Self.scripts.withLock({ $0[url] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        switch script {
        case .failBeforeResponse(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .response(let status, let chunks):
            deliver(status: status, chunks: chunks)
            client?.urlProtocolDidFinishLoading(self)
        case .responseThenFail(let status, let chunks, let code):
            deliver(status: status, chunks: chunks)
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}

    private func deliver(status: Int, chunks: [Data]) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
    }
}
