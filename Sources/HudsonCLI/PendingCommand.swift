import ArgumentParser
import Foundation
import GmailKit
import Store

/// Lists triage actions queued locally but not yet confirmed by Gmail — the
/// local `mutation_queue`, read via `LocalRuntime` (never the network).
struct PendingCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pending",
        abstract: "List triage actions queued locally but not yet confirmed by Gmail."
    )

    func run() async throws {
        do {
            let runtime = try await LocalRuntime.local()
            let mutations = try await runtime.database.pendingMutations(account: runtime.account.email)
            guard !mutations.isEmpty else {
                print("No pending mutations.")
                return
            }
            for mutation in mutations {
                // Message and label ids are Gmail-issued but still echoed
                // back verbatim from the queue row — single-line sanitize
                // both as a defense-in-depth match for `list`/`show`'s row
                // output (a user-named label is user-controlled text one
                // level up, same as a message's From/Subject).
                let id = Sanitizer.terminalSafe(mutation.messageID, singleLine: true)
                let labelID = Sanitizer.terminalSafe(mutation.labelID, singleLine: true)
                let op = mutation.op.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)
                print("\(id)  \(op) \(labelID)  [\(mutation.state)]")
            }
        } catch let error as GmailError {
            throw reportAndFail(error)
        }
    }
}
