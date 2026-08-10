import ArgumentParser
import Foundation
import GmailKit
import Store

/// Prints the newest messages from the LOCAL store — never the network.
struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List recent messages from the local store."
    )

    @Option(help: "How many messages to show.")
    var limit = 25

    func run() async throws {
        do {
            let runtime = try await LocalRuntime.local()
            let rows = try await runtime.database.recentMessages(
                account: runtime.account.email, limit: limit)
            guard !rows.isEmpty else {
                print("Store is empty — run `hudson sync` first.")
                return
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d HH:mm"
            for row in rows {
                let date = Date(timeIntervalSince1970: Double(row.internalDate) / 1_000)
                let unread = row.labelIDs.contains("UNREAD") ? "●" : " "
                // Single-line variant: a crafted subject/from with an embedded
                // newline must not be able to forge an extra row of output.
                let from = Sanitizer.terminalSafe(row.fromLine, singleLine: true).prefix(28)
                let subject = Sanitizer.terminalSafe(row.subject, singleLine: true).prefix(60)
                print("\(unread) \(row.id)  \(formatter.string(from: date))  "
                    + "\(from.padding(toLength: 28, withPad: " ", startingAt: 0))  \(subject)")
            }
        } catch let error as GmailError {
            throw reportAndFail(error)
        }
    }
}
