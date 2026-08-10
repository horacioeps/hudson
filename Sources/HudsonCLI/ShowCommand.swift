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
            // Single-line for the header fields: an embedded newline in From/To/Subject
            // must not be able to forge fake header-looking lines under the real block
            // (same class of fix the brief mandated for `list`'s rows). The body below
            // keeps the default, multi-line-preserving variant.
            print("From:    \(Sanitizer.terminalSafe(row.fromLine, singleLine: true))")
            print("To:      \(Sanitizer.terminalSafe(row.toLine, singleLine: true))")
            print("Subject: \(Sanitizer.terminalSafe(row.subject, singleLine: true))")
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
