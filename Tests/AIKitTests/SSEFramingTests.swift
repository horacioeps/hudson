import Foundation
import Testing

@testable import AIKit

/// Tests for `SSEFraming`, the pure byte→event SSE parser that
/// `URLSessionLLMHTTP` drives over a real socket (architecture pillar 1:
/// "genuine streaming byte seam"). Exercised directly on byte fixtures here
/// so no network double or event loop is needed to prove the framing logic
/// itself is correct — including the case that actually matters for a live
/// stream: a chunk boundary landing mid-event.

// MARK: - single + multi event framing

/// One complete SSE block (`data:` + a following blank line) frames to
/// exactly one event, and the buffer has nothing left over.
@Test func framesSingleEvent() {
    let buffer = Data("event: content_block_delta\ndata: {\"text\":\"hi\"}\n\n".utf8)

    let (events, remainder) = SSEFraming.frame(buffer)

    #expect(events == [SSEEvent(event: "content_block_delta", data: "{\"text\":\"hi\"}")])
    #expect(remainder.isEmpty)
}

/// A buffer containing several complete events frames all of them, in order,
/// in one pass — this is what a chunk that happens to carry a whole burst of
/// deltas looks like.
@Test func framesMultipleEventsInOneBuffer() {
    let buffer = Data(
        """
        event: content_block_delta
        data: {"text":"Hel"}

        event: content_block_delta
        data: {"text":"lo"}

        event: message_stop
        data: {}


        """.utf8)

    let (events, remainder) = SSEFraming.frame(buffer)

    #expect(events == [
        SSEEvent(event: "content_block_delta", data: "{\"text\":\"Hel\"}"),
        SSEEvent(event: "content_block_delta", data: "{\"text\":\"lo\"}"),
        SSEEvent(event: "message_stop", data: "{}"),
    ])
    // The fixture's trailing blank line leaves nothing but blank content
    // behind, which frames to no further event and an empty remainder.
    #expect(remainder.isEmpty)
}

/// An event with no `event:` line (OpenAI-compat style — `data:` only) still
/// frames correctly, with `event` reported as `nil`.
@Test func framesDataOnlyEventWithNilEventName() {
    let buffer = Data("data: {\"choices\":[]}\n\n".utf8)

    let (events, _) = SSEFraming.frame(buffer)

    #expect(events == [SSEEvent(event: nil, data: "{\"choices\":[]}")])
}

/// Multiple `data:` lines within ONE event join with `\n`, per the SSE spec
/// (a provider may wrap a large payload across several `data:` lines rather
/// than one long line).
@Test func joinsMultipleDataLinesWithNewline() {
    let buffer = Data("data: line one\ndata: line two\n\n".utf8)

    let (events, _) = SSEFraming.frame(buffer)

    #expect(events == [SSEEvent(event: nil, data: "line one\nline two")])
}

// MARK: - partial chunks across boundaries (the case that matters for a live stream)

/// Feeding the SAME bytes as two chunks — split mid-line, well before the
/// terminating blank line — must NOT frame a premature/partial event: the
/// first call reports zero events and carries everything forward as
/// `remainder`.
@Test func partialChunkBeforeAnyBoundaryYieldsNoEventsAndFullRemainder() {
    let full = "event: content_block_delta\ndata: {\"text\":\"hi\"}\n\n"
    let splitIndex = full.index(full.startIndex, offsetBy: 10) // mid "content_block_delta"
    let firstHalf = Data(full[full.startIndex..<splitIndex].utf8)

    let (events, remainder) = SSEFraming.frame(firstHalf)

    #expect(events.isEmpty)
    #expect(remainder == firstHalf)
}

/// The canonical "chunk boundary splits an event mid-token" case: feed half
/// the bytes (no `\n\n` yet, so nothing frames), thread the `remainder` into
/// a second buffer with the rest of the bytes appended, and the SECOND call
/// must frame the complete event exactly as if it had arrived in one piece.
@Test func reassemblesEventSplitAcrossTwoChunks() {
    let full = "event: content_block_delta\ndata: {\"text\":\"hello world\"}\n\n"
    let splitIndex = full.index(full.startIndex, offsetBy: 30) // inside the data JSON
    let firstHalf = Data(full[full.startIndex..<splitIndex].utf8)
    let secondHalf = Data(full[splitIndex...].utf8)

    let (firstEvents, remainder) = SSEFraming.frame(firstHalf)
    #expect(firstEvents.isEmpty)

    var rejoined = remainder
    rejoined.append(secondHalf)
    let (events, finalRemainder) = SSEFraming.frame(rejoined)

    #expect(events == [
        SSEEvent(event: "content_block_delta", data: "{\"text\":\"hello world\"}"),
    ])
    #expect(finalRemainder.isEmpty)
}

/// Splitting exactly ACROSS the two-byte `\n\n` separator itself (first `\n`
/// in chunk one, second `\n` in chunk two) is the tightest version of the
/// same case and must still reassemble correctly.
@Test func reassemblesEventSplitExactlyOnTheBlankLineSeparator() {
    let full = "data: hi\n\n"
    let splitIndex = full.index(full.startIndex, offsetBy: 9) // right after the first \n
    let firstHalf = Data(full[full.startIndex..<splitIndex].utf8)
    let secondHalf = Data(full[splitIndex...].utf8)

    let (firstEvents, remainder) = SSEFraming.frame(firstHalf)
    #expect(firstEvents.isEmpty)

    var rejoined = remainder
    rejoined.append(secondHalf)
    let (events, _) = SSEFraming.frame(rejoined)

    #expect(events == [SSEEvent(event: nil, data: "hi")])
}

// MARK: - comments/keepalives are ignored

/// SSE comment lines (`:`-prefixed, used by providers as keepalive pings)
/// dispatch no event and must not surface as an empty/garbage `SSEEvent`.
@Test func ignoresCommentOnlyKeepaliveBlocks() {
    let buffer = Data(": keepalive\n\ndata: real event\n\n".utf8)

    let (events, _) = SSEFraming.frame(buffer)

    #expect(events == [SSEEvent(event: nil, data: "real event")])
}

/// A run of keepalive pings between two real events is fully filtered out —
/// the surviving events are exactly the two real ones, in order.
@Test func filtersKeepalivesBetweenRealEvents() {
    let buffer = Data(
        "data: first\n\n: ping\n\n: ping\n\ndata: second\n\n".utf8)

    let (events, _) = SSEFraming.frame(buffer)

    #expect(events == [
        SSEEvent(event: nil, data: "first"),
        SSEEvent(event: nil, data: "second"),
    ])
}

/// An entirely empty buffer frames to no events and no remainder — the
/// steady-state "nothing received yet" case.
@Test func emptyBufferFramesToNothing() {
    let (events, remainder) = SSEFraming.frame(Data())

    #expect(events.isEmpty)
    #expect(remainder.isEmpty)
}

// MARK: - CR/LF tolerance (\r\n line endings)

/// The exact repro from the CR/LF-dead-code review finding: an `event:` +
/// `data:` block whose LINES are `\r\n`-terminated but whose blank-line
/// separator is a bare `\n\n` (mixed line endings, as a proxy that rewrites
/// only the separator might produce). Pre-fix, this returned `events == []`
/// forever: the `\r` immediately before the separator's first `\n` fused
/// into one grapheme cluster in the `Substring` search, so `"\n\n"` never
/// matched and the buffer never drained. Also proves the parsed `data`
/// value is `"bar"`, not `"bar\r"` — the per-line CR has to come off too.
@Test func stripsPerLineCarriageReturnBeforeBareLFSeparator() {
    let buffer = Data("event: foo\r\ndata: bar\r\n\n".utf8)

    let (events, remainder) = SSEFraming.frame(buffer)

    #expect(events == [SSEEvent(event: "foo", data: "bar")])
    #expect(remainder.isEmpty)
}

/// The full CRLF case: EVERY line ending, including the blank-line
/// separator itself, is `\r\n` (`\r\n\r\n`) — how a strictly RFC-compliant
/// CRLF-only HTTP server frames SSE. Pre-fix, the separator search for
/// `"\n\n"` never matched at all (the `\r` before each `\n` fuses into one
/// grapheme cluster), so this buffer would silently accumulate forever with
/// zero events and a non-empty, never-draining remainder.
@Test func framesEventWhoseSeparatorIsFullCRLFCRLF() {
    let buffer = Data("event: content_block_delta\r\ndata: {\"text\":\"hi\"}\r\n\r\n".utf8)

    let (events, remainder) = SSEFraming.frame(buffer)

    #expect(events == [SSEEvent(event: "content_block_delta", data: "{\"text\":\"hi\"}")])
    #expect(remainder.isEmpty)
}

/// Multiple full-CRLF events back to back frame in order, proving the fix
/// holds across repeated separators, not just a single trailing one.
@Test func framesMultipleFullCRLFEventsInOrder() {
    let buffer = Data(
        "data: one\r\n\r\ndata: two\r\n\r\ndata: three\r\n\r\n".utf8)

    let (events, remainder) = SSEFraming.frame(buffer)

    #expect(events == [
        SSEEvent(event: nil, data: "one"),
        SSEEvent(event: nil, data: "two"),
        SSEEvent(event: nil, data: "three"),
    ])
    #expect(remainder.isEmpty)
}

/// A CRLF event split across two chunks — mirroring
/// `reassemblesEventSplitAcrossTwoChunks` above but with `\r\n` line
/// endings — must still reassemble once the remainder is threaded into the
/// next call.
@Test func reassemblesFullCRLFEventSplitAcrossTwoChunks() {
    let full = "event: content_block_delta\r\ndata: {\"text\":\"hello world\"}\r\n\r\n"
    let splitIndex = full.index(full.startIndex, offsetBy: 30) // inside the data JSON
    let firstHalf = Data(full[full.startIndex..<splitIndex].utf8)
    let secondHalf = Data(full[splitIndex...].utf8)

    let (firstEvents, remainder) = SSEFraming.frame(firstHalf)
    #expect(firstEvents.isEmpty)

    var rejoined = remainder
    rejoined.append(secondHalf)
    let (events, finalRemainder) = SSEFraming.frame(rejoined)

    #expect(events == [
        SSEEvent(event: "content_block_delta", data: "{\"text\":\"hello world\"}"),
    ])
    #expect(finalRemainder.isEmpty)
}
