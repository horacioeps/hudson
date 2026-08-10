import ArgumentParser
import Foundation
import GmailKit
import Store

/// Thread-grouped inbox view, optionally filtered by split category.
struct InboxCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inbox",
        abstract: "List threads in the inbox."
    )

    @Option(help: "Filter by split category (e.g., 'promotions').")
    var split: String?

    @Option(help: "How many threads to show.")
    var limit = 25

    func run() async throws {
        do {
            let runtime = try await LocalRuntime.local()
            let threads = try await runtime.database.inboxThreads(
                account: runtime.account.email,
                split: split,
                limit: limit
            )

            guard !threads.isEmpty else {
                print("Inbox empty — run `hudson sync`.")
                return
            }

            for thread in threads {
                let unread = thread.unread ? "●" : " "
                let from = Sanitizer.terminalSafe(thread.fromSummary, singleLine: true).prefix(28)
                let subject = Sanitizer.terminalSafe(thread.subject, singleLine: true).prefix(60)
                let attachment = thread.hasAttachment ? " 📎" : ""
                print("\(unread) [\(thread.messageCount)] \(from.padding(toLength: 28, withPad: " ", startingAt: 0))  "
                    + "\(subject)\(attachment)")
            }
        } catch let error as GmailError {
            throw reportAndFail(error)
        }
    }
}
