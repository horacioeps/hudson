import AppKit
import SwiftUI
import Testing

/// Regression coverage for the exact defect a review caught in
/// `RootView`'s Task 4 gate: `init(model:)` used to build its
/// `OnboardingModel` — and wire its escaping `onConnected` closure over
/// `self` — eagerly, INSIDE the initializer, before SwiftUI had ever run
/// `body` for that view's identity. A closure that captures a value-type
/// View's `self` at that point closes over a "pre-install" copy of its
/// `@State`; when the closure fires later (a real user finishing sign-in),
/// its writes land on that disconnected copy and the live-rendered tree
/// never observes them — the app silently never leaves onboarding, even
/// though the account really did get persisted.
///
/// `RootView` can't be unit-tested for this directly: its `model`/
/// `onboarding` are `private @State`, and (confirmed empirically while
/// building this file) reading ANY `@State` property back off the `View`
/// value a test constructs — even after hosting it in an `NSHostingView`
/// and forcing `layout()` — never reflects writes the live tree makes
/// later, REGARDLESS of whether those writes are "safe" or "buggy"; that
/// local value was never the one SwiftUI's state graph is driving. The only
/// way a write's effect becomes externally observable is through a
/// reference type reachable from BOTH sides — which is exactly the shape
/// `RootView.makeOnboardingModel`'s fix relies on (`onConnected` mutates
/// `@State` through `self`, but the mutation's downstream EFFECTS — a new
/// `AppModel`, `startAutoSync()` — are what a real user actually sees).
///
/// So this file reproduces the identical minimal shape — a `View` with
/// `@State`, an escaping closure capturing `self`, wired either inside a
/// custom `init` (the old, buggy `RootView.init(model:)` shape) or inside
/// `.task` (the fix — `RootView`'s ONE call site for
/// `makeOnboardingModel`, now shared by both boot paths) — and observes
/// each write's success or loss through a plain reference-type `Probe`
/// both the view and the test hold, standing in for the mailbox swap
/// `RootView.makeOnboardingModel`'s `onConnected` performs.
@MainActor
private final class Probe {
    /// What the view's `@State` held the last time it changed — written by
    /// `ProbeView`'s `.onChange(of:)`, so this only updates when a write
    /// actually reached the LIVE `@State`, never when it landed on a
    /// disconnected pre-install copy.
    private(set) var lastObservedState = 0
    /// Set by the view, inside `.task`, to the `.task`-wired flavor of the
    /// swap closure — a stand-in for `RootView` handing a freshly built
    /// `OnboardingModel.onConnected` to the outside world (there, by being
    /// invoked from a real sign-in; here, by the test calling it directly).
    var fireTaskWiredSwap: (() -> Void)?

    func recordStateChange(_ value: Int) { lastObservedState = value }
}

/// Mirrors `RootView`'s exact split: an `@State` value mutated by an
/// escaping closure that captures `self`, wired either in `init`
/// (`wireInInit: true` — the pre-fix `init(model:)` shape) or in `.task`
/// (`wireInInit: false` — the fix, matching `RootView`'s single
/// `makeOnboardingModel` call site).
private struct ProbeView: View {
    @State private var connectedState = 0
    private let probe: Probe
    private let wireInInit: Bool
    /// The pre-fix shape's closure, built in `init` — nothing outside this
    /// view can reach it (mirrors `OnboardingModel.onConnected` being wired
    /// entirely inside `RootView.makeOnboardingModel`, invisible to a
    /// caller); the test instead measures ITS EFFECT via `probe`.
    private var fireInitWiredSwap: (() -> Void)?

    init(probe: Probe, wireInInit: Bool) {
        self.probe = probe
        self.wireInInit = wireInInit
        if wireInInit {
            // The exact pre-fix pattern: `[self]` capture, set up before
            // this view's identity has ever run `body` once.
            self.fireInitWiredSwap = { [self] in self.connectedState = 42 }
        }
    }

    var body: some View {
        Color.clear
            .task {
                if !wireInInit, probe.fireTaskWiredSwap == nil {
                    // The fix's shape: same capture, same mutation, but
                    // built here — guaranteed to run only after `body` has
                    // executed at least once for this identity, exactly
                    // like `RootView`'s `.task`-driven `makeOnboardingModel`
                    // call.
                    probe.fireTaskWiredSwap = { [self] in self.connectedState = 42 }
                } else if wireInInit {
                    probe.fireTaskWiredSwap = fireInitWiredSwap
                }
            }
            .onChange(of: connectedState) { _, newValue in
                probe.recordStateChange(newValue)
            }
    }
}

/// The bug `RootView.init(model:)` had: firing a swap closure captured
/// INSIDE `init` — after the view is hosted and installed, just like a real
/// user completing sign-in sometime after `RootView` first appears — never
/// reaches the live `@State`. `probe.lastObservedState` stays at its
/// initial value forever.
@MainActor
@Test func swapClosureCapturedInsideInitLosesItsWriteToTheLiveView() async throws {
    let probe = Probe()
    let view = ProbeView(probe: probe, wireInInit: true)
    let host = NSHostingView(rootView: view)
    host.frame = .init(x: 0, y: 0, width: 10, height: 10)
    host.layout()
    try await Task.sleep(for: .milliseconds(50))
    host.layout()

    probe.fireTaskWiredSwap?()  // fire the init-captured closure, well after install
    try await Task.sleep(for: .milliseconds(50))
    host.layout()

    #expect(probe.lastObservedState == 0)  // the write never reached the live tree
}

/// `RootView`'s actual fix: the identical closure shape, but built inside
/// `.task` — SwiftUI guarantees that only runs after `body`'s first pass —
/// correctly reaches the live `@State` when fired later.
@MainActor
@Test func swapClosureCapturedInsideTaskReachesTheLiveView() async throws {
    let probe = Probe()
    let view = ProbeView(probe: probe, wireInInit: false)
    let host = NSHostingView(rootView: view)
    host.frame = .init(x: 0, y: 0, width: 10, height: 10)
    host.layout()
    try await Task.sleep(for: .milliseconds(50))
    host.layout()

    probe.fireTaskWiredSwap?()  // fire the .task-captured closure
    try await Task.sleep(for: .milliseconds(50))
    host.layout()

    #expect(probe.lastObservedState == 42)  // the write DID reach the live tree
}

// MARK: - The REVERSE gate (Task 5: "Disconnect account")

/// Mirrors `ProbeView` above, but for the shape `RootView`'s reverse gate
/// actually uses: `.onChange(of: model?.needsOnboarding)`, built inside
/// `body` (never `init`), rebuilding `onboarding` only on a genuine
/// TRANSITION of the watched value — exactly how `needsOnboarding` behaves
/// in practice (it starts `false` for a connected launch and flips `true`
/// only later, when `AppModel.disconnectAccount()` clears `account`).
/// `flag` stands in for `needsOnboarding`; `connectedState` stands in for
/// `onboarding` being (re)built. Proves the SAME "captured after body's
/// first pass reaches live `@State`" guarantee `.task` relies on also holds
/// for `.onChange` — the mechanism `RootView` needs for the reverse gate,
/// since `.task` itself only runs once per view identity and can't be
/// re-triggered by a LATER `needsOnboarding` flip.
private struct ReverseProbeView: View {
    @State private var flag = false
    @State private var connectedState = 0
    private let probe: Probe

    init(probe: Probe) {
        self.probe = probe
    }

    var body: some View {
        Color.clear
            .onChange(of: flag) { _, newValue in
                // Built here — inside a body-attached modifier — so `self`
                // is always a body-bound copy, the same guarantee `.task`'s
                // closure relies on above.
                if newValue { self.connectedState = 42 }
            }
            .onChange(of: connectedState) { _, newValue in
                probe.recordStateChange(newValue)
            }
            .task {
                // Hands the test a way to flip `flag` from OUTSIDE this
                // view's identity — standing in for `AppModel.account`
                // being cleared by a real "Disconnect" tap sometime after
                // this view first appeared.
                probe.fireTaskWiredSwap = { [self] in self.flag = true }
            }
    }
}

/// `RootView`'s reverse-gate fix: an `.onChange(of:)` closure built inside
/// `body`, firing only once `flag` genuinely transitions (never for the
/// view's initial appearance — SwiftUI's `onChange` doesn't fire for that),
/// correctly reaches the live `@State` when the transition happens later.
@MainActor
@Test func onChangeCapturedInsideBodyReachesTheLiveViewOnALaterFlip() async throws {
    let probe = Probe()
    let view = ReverseProbeView(probe: probe)
    let host = NSHostingView(rootView: view)
    host.frame = .init(x: 0, y: 0, width: 10, height: 10)
    host.layout()
    try await Task.sleep(for: .milliseconds(50))
    host.layout()

    probe.fireTaskWiredSwap?()  // flips `flag` — the disconnect-flips-needsOnboarding moment
    try await Task.sleep(for: .milliseconds(50))
    host.layout()

    #expect(probe.lastObservedState == 42)  // the onChange-driven write DID reach the live tree
}
