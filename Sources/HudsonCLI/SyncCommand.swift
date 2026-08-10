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
            // Drains any locally-queued mutations (offline / --no-flush
            // triage) to Gmail and retires whatever's already confirmed —
            // without this, `hudson sync` neither delivers queued triage
            // nor clears a stale overlay once its echo has landed (M3
            // final-review Fix 3). Best-effort like `TriageRunner.flush`:
            // a flush failure must not fail the sync that already
            // succeeded above.
            await flushMutations(runtime)
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

    /// One best-effort `flushOnce()` pass: sends whatever's queued and
    /// retires whatever's already confirmed. Mirrors `TriageRunner.flush`'s
    /// swallow-and-report contract — the sync above already succeeded, so a
    /// flush problem (offline, Keychain gate, Gmail rejecting a request) is
    /// reported, never a hard failure of `hudson sync` itself.
    private func flushMutations(_ runtime: Runtime) async {
        do {
            let report = try await runtime.flusher.flushOnce()
            print("flushed: \(report.flushed) sent, \(report.retired) retired, \(report.dropped) dropped")
        } catch let error as GmailError {
            print("mutation flush failed, will retry (\(error.cliMessage))")
        } catch {
            // Non-GmailError failures here are almost always a DatabaseError,
            // whose description embeds raw SQL — never print it directly
            // (Sanitizer discipline, spec §9.1); the type name is enough to
            // diagnose without leaking query text.
            print("mutation flush failed, will retry (\(type(of: error)))")
        }
    }
}
