import AIKit
import Foundation
import Store

/// The Summarize chip's view model: streams a thread summary into `text` when
/// the user taps the chip, and surfaces the "turn AI on" state when the
/// feature isn't opted in. `@MainActor @Observable` for the same reason as
/// every other Hudson view model (`ComposerModel`, `ThreadModel`) — SwiftUI
/// reads `text`/`isStreaming`/`needsSetup` on the main thread while the
/// Summarize call is `async`.
///
/// **Privacy #1 — summarize is user-initiated only.** Nothing here runs on
/// its own: `summarize(threadID:)` is called ONLY from the chip's tap handler,
/// never on thread-open or scroll (no auto-run), and it is the ONE place in
/// the UI that mints an `Invocation` (`.userInvoked(.summarize)` — the token
/// that, per `EgressGuard`/`Invocation`, is equivalent to the user having
/// pressed the button). Egress still passes through `EgressGuard`'s opt-in
/// gate underneath; this model just drives it and renders the result.
///
/// **The `makeSummarize` seam.** The `Summarize` is built lazily, per tap,
/// from a factory injected at init — production defaults it to `AIBootstrap`
/// (ai_config + Keychain → provider → `EgressGuard` → `Summarize`), which
/// returns `nil` fail-closed when the feature isn't opted in; tests inject a
/// `Summarize` layered over a scripted provider so the whole stream/opt-in
/// path is exercised with no network or Keychain.
@MainActor
@Observable
public final class SummaryModel {
    private let makeSummarize: () async -> Summarize?

    /// The summary text streamed so far — grows delta-by-delta as the
    /// provider responds, and is the ONLY thing the chip's expanded area
    /// renders. Empty before any tap and after `reset()`.
    public private(set) var text: String = ""

    /// True from the tap until the stream finishes — drives the chip's
    /// in-progress affordance and guards against a double-tap starting a
    /// second overlapping summarize.
    public private(set) var isStreaming = false

    /// True when summarize isn't opted in (the factory returned `nil`, or the
    /// opt-in was revoked mid-flight and `EgressGuard` threw `notOptedIn`) —
    /// the chip shows `setupBannerText` instead of a summary. Set WITHOUT any
    /// content having left the machine.
    public private(set) var needsSetup = false

    /// A user-visible strip for a summarize FAILURE that isn't the
    /// not-opted-in case (an empty/unknown thread, a provider/transport
    /// error). `nil` when there's nothing to say.
    public private(set) var banner: String?

    /// Shown when `needsSetup` — the exact CLI incantation that opts summarize
    /// in (`ai config` is the ONLY way opt-in is turned on, per spec §8).
    public static let setupBannerText =
        "Enable AI first: hudson ai config --feature summarize --provider anthropic "
        + "--model claude-haiku-4-5 --opt-in"

    /// `makeSummarize` is optional-with-nil rather than a defaulted closure
    /// because a default argument can't capture the sibling `database`/
    /// `account` params — so the real `AIBootstrap` default is assembled in
    /// the body instead (mirrors `ComposerModel`'s `makeService` seam).
    /// Production callers omit it; tests pass a scripted-provider-backed one.
    public init(
        database: HudsonDatabase,
        account: String,
        makeSummarize: (() async -> Summarize?)? = nil
    ) {
        self.makeSummarize = makeSummarize ?? {
            await AIBootstrap.makeSummarize(database: database, account: account)
        }
    }

    /// Summarizes `threadID`, streaming the result into `text`. Called ONLY
    /// from the chip's explicit tap — this is the user action the
    /// `.userInvoked(.summarize)` token below stands for. Fail-closed on
    /// every axis: a `nil` factory or a mid-flight opt-in revocation both set
    /// `needsSetup` with ZERO egress (the opt-in gate lives in `EgressGuard`,
    /// which throws before any provider call); a double-tap while already
    /// streaming is ignored.
    public func summarize(threadID: String) async {
        guard !isStreaming else { return }

        // Fresh run: clear any prior thread's summary/state so the chip never
        // shows a stale summary or a banner from a previous tap.
        text = ""
        needsSetup = false
        banner = nil

        guard let summarize = await makeSummarize() else {
            // Fail closed — the feature isn't opted in, so there is nothing to
            // build and nothing egresses.
            needsSetup = true
            return
        }

        isStreaming = true
        defer { isStreaming = false }
        do {
            // The chip tap IS the explicit invocation — the ONLY `Invocation`
            // minted anywhere in the UI. `EgressGuard` still re-checks the
            // opt-in row underneath before the provider is ever called.
            let stream = try await summarize.summarize(
                threadID: threadID, invocation: .userInvoked(.summarize))
            for try await delta in stream {
                text += delta
            }
        } catch AIError.notOptedIn(_) {
            // Opt-in was revoked between the factory build and now — the guard
            // threw before the provider was called, so nothing left the
            // machine. Present it as needs-setup, same as a nil factory.
            needsSetup = true
            text = ""
        } catch {
            // An empty/unknown thread, or a provider/transport error — surface
            // it without pretending a summary exists.
            banner = "Couldn't summarize this thread."
            text = ""
        }
    }

    /// Clears the summary and any banner/setup state — called when the reading
    /// pane switches to a different thread so the chip resets to its
    /// untapped "Summarize thread" state rather than carrying the previous
    /// thread's summary over.
    public func reset() {
        text = ""
        needsSetup = false
        banner = nil
    }
}
