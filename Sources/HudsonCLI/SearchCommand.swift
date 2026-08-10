import ArgumentParser
import Foundation
import GmailKit
import Store

/// Instant full-text search over the local store via the query layer.
struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search messages in the local store."
    )

    @Argument(help: "Query term(s) to search for.")
    var query: String

    @Option(help: "How many results to show.")
    var limit = 25

    @Flag(help: "Search only the inbox.")
    var inbox = false

    func run() async throws {
        do {
            let runtime = try await LocalRuntime.local()
            let scope: SearchScope = inbox ? .inbox : .all
            let hits = try await runtime.database.searchMessages(
                account: runtime.account.email,
                query: query,
                limit: limit,
                scope: scope
            )

            guard !hits.isEmpty else {
                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count < 2 {
                    print("Query too short (minimum 2 characters).")
                } else {
                    print("No results found.")
                }
                return
            }

            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d HH:mm"
            for hit in hits {
                let date = Date(timeIntervalSince1970: Double(hit.internalDate) / 1_000)
                let from = Sanitizer.terminalSafe(hit.fromLine, singleLine: true).prefix(28)
                let subject = Sanitizer.terminalSafe(hit.subject, singleLine: true).prefix(60)
                print("\(hit.messageID)  \(formatter.string(from: date))  "
                    + "\(from.padding(toLength: 28, withPad: " ", startingAt: 0))  \(subject)")
            }
        } catch let error as GmailError {
            throw reportAndFail(error)
        }
    }
}
