import Foundation

/// One decoded Server-Sent Event: the optional `event:` field and the
/// (possibly multi-line, per the SSE spec) `data:` payload joined with `\n`.
/// A pure value — producing one has no dependency on `URLSession`, so the
/// framing logic below is exercised directly on byte fixtures in tests, with
/// no network double needed.
public struct SSEEvent: Sendable, Equatable {
    public let event: String?
    public let data: String

    public init(event: String?, data: String) {
        self.event = event
        self.data = data
    }
}

/// The pure SSE line-framer. Given the bytes accumulated so far, splits out
/// every COMPLETE event — terminated by a blank line, SSE's `\n\n` event
/// separator — and returns whatever incomplete tail remains.
///
/// Network chunk boundaries rarely land on an SSE event boundary (a chunk
/// can end mid-token inside a `data:` line's JSON). Callers thread the
/// returned `remainder` into the *next* call's input rather than assuming
/// one network chunk is one event; that's what makes "reassembles an event
/// split across chunks" a property of this pure function, provable on fixed
/// byte fixtures, rather than something `URLSessionLLMHTTP` has to get right
/// against a live, non-reproducible socket.
///
/// Comment lines (SSE's `:`-prefixed keepalive pings, which providers send
/// to hold the connection open) and any block with no `data:` line are
/// silently dropped — a comment-only block dispatches no event per the SSE
/// spec, which is how a keepalive never surfaces as a bogus empty event.
public enum SSEFraming {
    public static func frame(_ buffer: Data) -> (events: [SSEEvent], remainder: Data) {
        // Strip \r bytes BEFORE decoding to String/Substring. Swift's
        // String/Substring model "\r\n" as a SINGLE extended grapheme
        // cluster (one `Character`), not two — so a `Substring` search for
        // the two-LF blank-line separator ("\n\n") can never match text
        // where a `\r` sits directly before a `\n` (i.e. any `\r\n\r\n` or
        // `\r\n\n` separator): the `\r` fuses with the following `\n` into
        // one Character, so two adjacent bare "\n" Characters never appear
        // and the block silently never frames. Removing every `\r` byte on
        // the raw buffer, before any grapheme-cluster-based text operation
        // runs, sidesteps that entirely and makes this framer's claimed
        // CR/LF tolerance real. SSE only ever emits `\r` immediately before
        // `\n` (never as a standalone line terminator), so dropping the
        // byte outright is equivalent to normalizing `\r\n` -> `\n` for all
        // real provider/proxy traffic.
        let normalized = strippingCarriageReturns(buffer)
        // SSE bodies from both providers are UTF-8 JSON, so decoding the
        // buffer once up front (rather than re-decoding per line) keeps this
        // a single linear pass over the text.
        let text = String(decoding: normalized, as: UTF8.self)
        var events: [SSEEvent] = []
        var rest = Substring(text)
        while let separatorRange = rest.range(of: "\n\n") {
            let block = rest[rest.startIndex..<separatorRange.lowerBound]
            if let event = parse(block: block) {
                events.append(event)
            }
            rest = rest[separatorRange.upperBound...]
        }
        return (events, Data(rest.utf8))
    }

    /// Drops every `\r` (0x0D) byte from `buffer`. See the WHY-comment in
    /// `frame(_:)` for why this must happen on raw bytes, before any
    /// `String`/`Substring` view of the data exists.
    private static func strippingCarriageReturns(_ buffer: Data) -> Data {
        guard buffer.contains(0x0D) else { return buffer }
        return Data(buffer.filter { $0 != 0x0D })
    }

    /// Parses one blank-line-delimited block into an `SSEEvent`. Lines are
    /// `field: value`; fields Hudson's providers don't need (`id:`,
    /// `retry:`, ...) and comment lines (leading `:`) are ignored. A block
    /// with no `data:` line at all (pure comment/keepalive, or a stray blank
    /// block) parses to `nil` so it never dispatches.
    ///
    /// `block` has already had every `\r` byte stripped by `frame(_:)`
    /// before this runs, so lines never carry a trailing `\r` here.
    private static func parse(block: Substring) -> SSEEvent? {
        var eventName: String?
        var dataLines: [Substring] = []
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty || line.hasPrefix(":") { continue }
            if let value = fieldValue("event:", in: line) {
                eventName = String(value)
            } else if let value = fieldValue("data:", in: line) {
                dataLines.append(value)
            }
        }
        guard !dataLines.isEmpty else { return nil }
        return SSEEvent(event: eventName, data: dataLines.joined(separator: "\n"))
    }

    /// Strips `prefix` and the SSE-optional single leading space after the
    /// colon (`"data: x"` and `"data:x"` are both valid per spec).
    private static func fieldValue(_ prefix: String, in line: Substring) -> Substring? {
        guard line.hasPrefix(prefix) else { return nil }
        var value = line.dropFirst(prefix.count)
        if value.hasPrefix(" ") { value = value.dropFirst() }
        return value
    }
}

/// The streaming HTTP seam every LLM provider egresses through: a genuine
/// byte stream, never a buffered `Data` blob — buffering would defeat
/// first-token latency and the 5-series "streaming mandatory" requirement
/// (architecture pillar 1). This is a DIFFERENT seam from GmailKit's
/// `HTTPTransport` (buffered request/response JSON) — AIKit never reuses
/// that transport, by design.
///
/// Yields one `Data` per SSE event: the framed, prefix-stripped `data:`
/// payload (raw JSON bytes), ready for a provider to decode. The `event:`
/// field is consumed by the framer but not forwarded here — both Anthropic
/// and OpenAI-compatible event JSON carry their own type discriminator
/// inside the payload (`"type"`/`"object"`), so providers never need the
/// SSE-level `event:` line to disambiguate.
public protocol LLMHTTP: Sendable {
    func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<Data, Error>
}

/// Production `LLMHTTP`: drives `SSEFraming` over `URLSession.shared.bytes(for:)`,
/// the true byte-streaming API (as opposed to `URLSession.data(for:)`, which
/// buffers the whole response and would defeat streaming entirely).
public struct URLSessionLLMHTTP: LLMHTTP {
    /// Initializes the production streaming HTTP seam using the shared
    /// `URLSession`.
    public init() {}

    public func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<Data, Error> {
        let byteStream: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (byteStream, response) = try await URLSession.shared.bytes(for: request)
        } catch let error as AIError {
            // Already the right type (shouldn't happen from URLSession, but
            // keeps this rethrow exhaustive/future-proof).
            throw error
        } catch {
            // Mirrors GmailKit's `URLSessionTransport.send`: a raw
            // `URLError` (no connection, DNS failure, TLS failure, timeout,
            // ...) must never escape untyped — `AIError`'s doc comment
            // promises callers can switch over it exhaustively.
            throw AIError.transport(error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.transport("Response was not HTTP.")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AIError.httpStatus(httpResponse.statusCode)
        }

        return Self.frameEvents(from: byteStream)
    }

    /// Drives the byte-by-byte SSE framing loop over any `UInt8` async
    /// sequence — extracted out of `stream(_:)` so this trigger/flush logic
    /// (the actual byte-driven behavior that ships, as opposed to the pure
    /// `SSEFraming.frame` it calls) can be driven directly on an in-memory
    /// fixture sequence in tests, with no real socket or `URLProtocol`
    /// double required.
    static func frameEvents<Bytes: AsyncSequence & Sendable>(
        from byteStream: Bytes
    ) -> AsyncThrowingStream<Data, Error> where Bytes.Element == UInt8 {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var buffer = Data()
                    var previousByte: UInt8 = 0
                    for try await byte in byteStream {
                        buffer.append(byte)
                        // Re-framing on every byte would re-decode the whole
                        // accumulated buffer as UTF-8 each time — O(n^2) over
                        // a response. Instead, only re-frame the instant a
                        // blank-line separator (\n\n) could just have
                        // completed: the newly-arrived byte and the one
                        // before it are both \n. That bounds each frame()
                        // call's work to roughly one event's bytes, so the
                        // whole stream stays O(n) even though bytes arrive
                        // one at a time.
                        if byte == UInt8(ascii: "\n") && previousByte == UInt8(ascii: "\n") {
                            let (events, remainder) = SSEFraming.frame(buffer)
                            for event in events {
                                continuation.yield(Data(event.data.utf8))
                            }
                            buffer = remainder
                        }
                        previousByte = byte
                    }
                    // The connection can close without a final trailing
                    // blank line (EOF, reset, or truncation right after a
                    // `data:` line — no more bytes ever arrive to complete
                    // the \n\n separator the loop above waits for).
                    // `SSEFraming.frame` requires a LITERAL \n\n to
                    // recognize a block, so without this, any non-empty
                    // leftover `buffer` would be silently discarded as
                    // `remainder` and never dispatched — the exact "last
                    // event silently dropped" bug this comment used to only
                    // describe rather than prevent. Appending a synthetic
                    // terminator makes a dangling-but-otherwise-complete
                    // block still frame and flush like any other.
                    if !buffer.isEmpty {
                        buffer.append(contentsOf: [0x0A, 0x0A])
                        let (events, _) = SSEFraming.frame(buffer)
                        for event in events {
                            continuation.yield(Data(event.data.utf8))
                        }
                    }
                    continuation.finish()
                } catch let error as AIError {
                    continuation.finish(throwing: error)
                } catch {
                    // Same rewrap as the initial `bytes(for:)` call above:
                    // a raw `URLError` from mid-stream iteration (dropped
                    // connection, reset, timeout) must surface as a typed
                    // `AIError`, not escape untyped.
                    continuation.finish(throwing: AIError.transport(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
