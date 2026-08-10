import ArgumentParser
import Foundation
import GmailKit
import Store

/// Prints one message (headers + sanitized plain text) from the local store.
struct ShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show one message from the local store."
    )

    @Argument(help: "The message id (first column of `hudson list`).")
    var id: String

    func run() async throws {
        do {
            let runtime = try await Runtime.bootstrap()
            guard let fetched = try await runtime.database.message(
                id: id, account: runtime.account.email) else {
                print("No message \(Sanitizer.terminalSafe(id)) in the local store.")
                throw ExitCode.failure
            }
            let row = fetched.row
            print("From:    \(Sanitizer.terminalSafe(row.fromLine))")
            print("To:      \(Sanitizer.terminalSafe(row.toLine))")
            print("Subject: \(Sanitizer.terminalSafe(row.subject))")
            print("Labels:  \(row.labelIDs.joined(separator: ", "))")
            print()
            if let text = fetched.plainText {
                print(Sanitizer.terminalSafe(text))
            } else {
                print("(body not downloaded yet — run `hudson sync`)")
            }
        } catch let error as GmailError {
            throw reportAndFail(error)
        }
    }
}
