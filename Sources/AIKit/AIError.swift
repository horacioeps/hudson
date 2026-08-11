import Foundation

/// Errors surfaced by AIKit's feature layer. Kept in one place so callers
/// (CLI, UI) can switch exhaustively. Later M7 tasks extend this with
/// provider/transport cases; Task 1 needs only the opt-in gate.
public enum AIError: Error, Equatable, Sendable {
    /// Egress was attempted for a feature whose `ai_config.opt_in` is false or
    /// whose row is absent (never configured). Thrown by `EgressGuard` BEFORE
    /// any provider call, so a not-opted-in feature performs zero network I/O.
    case notOptedIn(AIFeature)
}
