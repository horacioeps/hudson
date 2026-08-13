import Foundation
import Testing

/// Thrown when `condition` never held. Failing loudly is the whole point:
/// returning quietly hands the timeout to whichever `#expect` follows, which
/// then reports some confusing value mismatch instead of "this never
/// happened" — and a wait whose condition is the assertion would pass.
struct ConditionNeverHeld: Error, CustomStringConvertible {
    let timeout: Duration
    let location: String

    var description: String { "condition at \(location) never held within \(timeout)" }
}

/// Polls `condition` on a bounded schedule instead of sleeping a fixed span.
///
/// A flat `Task.sleep` is a latent flake: it has to be long enough for the
/// slowest run on the busiest machine, and when the work under it grows — the
/// reading pane now hydrates every message in a thread rather than just the
/// newest — whatever number was chosen quietly stops being enough. Returns as
/// soon as the condition holds, so the common case is also faster than the
/// sleep it replaces.
///
/// `@MainActor` because every caller is asserting on a `@MainActor` view model.
@MainActor
func waitUntil(
    _ condition: () -> Bool, timeout: Duration = .seconds(3),
    file: StaticString = #fileID, line: UInt = #line
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    // The condition can land during that final sleep, so re-check once before
    // calling it a timeout rather than failing on a race with the deadline.
    guard !condition() else { return }
    throw ConditionNeverHeld(timeout: timeout, location: "\(file):\(line)")
}
