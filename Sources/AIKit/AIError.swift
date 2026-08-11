import Foundation

/// Errors surfaced by AIKit's feature layer. Kept in one place so callers
/// (CLI, UI) can switch exhaustively. Later M7 tasks extend this further with
/// provider-level cases (refusal, quota); Task 2 adds the transport-level
/// ones `URLSessionLLMHTTP` can throw before any SSE parsing happens.
public enum AIError: Error, Equatable, Sendable {
    /// Egress was attempted for a feature whose `ai_config.opt_in` is false or
    /// whose row is absent (never configured). Thrown by `EgressGuard` BEFORE
    /// any provider call, so a not-opted-in feature performs zero network I/O.
    case notOptedIn(AIFeature)

    /// `URLSession` returned a non-`HTTPURLResponse` (not expected for an
    /// `https://` request; kept for exhaustive handling parity with
    /// GmailKit's `HTTPTransport`, which guards the same case).
    case transport(String)

    /// The provider responded with a non-2xx HTTP status. Carries the raw
    /// status code so callers — including the 429 backoff providers add in
    /// Task 3/4 — can branch on it without re-parsing headers.
    case httpStatus(Int)
}
