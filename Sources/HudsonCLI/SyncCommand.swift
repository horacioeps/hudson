import ArgumentParser
import Foundation
import GmailKit
import Store

/// Drives the sync engine: repeated bounded passes until backfill and the
/// current hydration window are done (or --once for a single pass).
struct SyncCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Download mailbox changes into the local store."
    )

    @Flag(help: "Run exactly one bounded pass instead of syncing to completion.")
    var once = false

    @Flag(help: "Print local sync state and exit (no network).")
    var status = false

    func run() async throws {
        do {
            if status {
                let runtime = try await LocalRuntime.local()
                try await printStatus(runtime)
                return
            }
            let runtime = try await Runtime.bootstrap()
            var totalMessages = 0
            var totalBodies = 0
            repeat {
                let report = try await runtime.engine.syncOnce()
                totalMessages += report.backfilledThisPass
                totalBodies += report.bodiesHydrated
                print(
                    "synced: +\(report.backfilledThisPass) messages, "
                    + "\(report.eventsApplied) events, +\(report.bodiesHydrated) bodies"
                    + (report.backfillComplete ? "" : " (backfill continuing…)"))
                if once || (report.backfillComplete && report.bodiesHydrated == 0) { break }
            } while true
            print("Done. \(totalMessages) messages and \(totalBodies) bodies this run.")
        } catch let error as GmailError {
            throw reportAndFail(error)
        }
    }

    private func printStatus(_ runtime: LocalRuntime) async throws {
        let account = runtime.account
        print("Account:        \(account.email)")
        print("Backfill:       \(account.backfillState) (\(account.backfilledCount) messages)")
        print("History cursor: \(account.historyCursor.map(String.init) ?? "not recorded")")
    }
}
