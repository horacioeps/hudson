import Foundation
import Store
import Testing
@testable import HudsonUI

// MARK: - The reported bug: the FIRST frame must already be honest

/// **The regression test for the original report.**
///
/// A freshly connected account has `backfill_state = 'pending'`, and the user
/// sees the window before any async work can possibly have run. `isCatchingUp`
/// therefore has to be true SYNCHRONOUSLY, straight out of the initializer,
/// with no `await` anywhere — the old code declared it `false` and first
/// assigned it only after the opening `syncOnce()` returned, which is why the
/// footer said "All synced" and the inbox said "No messages here" while
/// hundreds of messages were still downloading.
@MainActor
@Test func aFreshlyConnectedAccountIsCatchingUpOnTheVeryFirstFrame() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "a@example.com", clientID: "id", consentedAt: .now)
    let account = try #require(try await db.primaryAccount())

    // No await between construction and the assertion — this is the first frame.
    let model = AppModel(database: db, account: account)

    #expect(model.isCatchingUp)
}

/// The mirror: an account whose backfill finished must NOT claim to be
/// downloading. Over-reporting is as dishonest as under-reporting.
@MainActor
@Test func aCompletedAccountIsNotCatchingUp() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "a@example.com", clientID: "id", consentedAt: .now)
    try await db.updateBackfill(
        email: "a@example.com", state: "complete", pageToken: nil, addedCount: 0)
    let account = try #require(try await db.primaryAccount())

    let model = AppModel(database: db, account: account)

    #expect(!model.isCatchingUp)
}

/// The demo mailbox never syncs, so a progress state it can never leave would
/// be a permanent lie.
@MainActor
@Test func theDemoMailboxNeverClaimsToBeCatchingUp() async throws {
    let db = try HudsonDatabase.inMemory()
    try await DemoData.seed(into: db, account: AppModel.demoAccount)
    let account = try await db.primaryAccount()

    let model = AppModel(database: db, account: account, isDemo: true)

    #expect(!model.isCatchingUp)
}

/// No account, nothing syncing.
@MainActor
@Test func noAccountMeansNotCatchingUp() {
    #expect(!AppModel.seedCatchingUp(account: nil, isDemo: false))
}

// MARK: - Fraction: ratchet, ceiling, completion

/// The bar never runs backwards. A message deleted mid-backfill shrinks the
/// live count, and without the ratchet the bar would visibly rewind.
@MainActor
@Test func theFractionNeverDecreasesWithinARun() async throws {
    let model = try await progressModel()

    model.applyBackfillProgress(
        .init(state: "listing", stored: 500, totalEstimate: 1_000, countBaseline: 0))
    let high = try #require(model.backfillFraction)

    model.applyBackfillProgress(
        .init(state: "listing", stored: 400, totalEstimate: 1_000, countBaseline: 0))

    #expect(model.backfillFraction == high)
}

/// A running bar is capped below 100%, because the denominator is Gmail's own
/// approximation. Claiming "almost done" on a number we know is inexact is the
/// failure mode that makes progress bars untrustworthy.
@MainActor
@Test func aRunningBarNeverClaimsMoreThanTheCeiling() async throws {
    let model = try await progressModel()

    model.applyBackfillProgress(
        .init(state: "listing", stored: 5_000, totalEstimate: 1_000, countBaseline: 0))

    #expect(model.backfillFraction == AppModel.backfillFractionCeiling)
}

/// Completion is signalled by state, never by the fraction reaching a
/// threshold — and it fills the bar, so it leaves the screen full rather than
/// stranded at the ceiling.
@MainActor
@Test func completionFillsTheBarAndClearsCatchingUp() async throws {
    let model = try await progressModel()
    model.applyBackfillProgress(
        .init(state: "listing", stored: 500, totalEstimate: 1_000, countBaseline: 0))

    model.applyBackfillProgress(
        .init(state: "complete", stored: 900, totalEstimate: 1_000, countBaseline: 0))

    #expect(model.backfillFraction == 1.0)
    #expect(!model.backfillProgress!.isRunning)
}

/// Before Gmail's first list page returns there is no denominator, so there is
/// no bar — an empty track beside the status line, never a fake.
@MainActor
@Test func anUnknownTotalProducesNoFraction() async throws {
    let model = try await progressModel()

    model.applyBackfillProgress(
        .init(state: "pending", stored: 0, totalEstimate: nil, countBaseline: nil))

    #expect(model.backfillFraction == nil)
    #expect(model.isCatchingUp)
}

/// A zero estimate must not divide.
@MainActor
@Test func aZeroEstimateProducesNoFraction() async throws {
    let model = try await progressModel()

    model.applyBackfillProgress(
        .init(state: "listing", stored: 0, totalEstimate: 0, countBaseline: 0))

    #expect(model.backfillFraction == nil)
}

/// **The blocker both reviewers found.** A reconnect leaves every message on
/// disk (`deleteAccount` deliberately keeps mail), so a re-list starts with the
/// stored count already at or above the fresh estimate. Deriving a fraction
/// there would pin the bar at its ceiling, motionless, for the whole re-list —
/// a worse claim than the status line it replaced. Re-listing mail the user
/// already has is not visible progress, so it gets no bar at all.
@MainActor
@Test func aRelistOverMailAlreadyOnDiskShowsNoBarRatherThanAPinnedCeiling() async throws {
    let model = try await progressModel()

    model.applyBackfillProgress(
        .init(state: "listing", stored: 880, totalEstimate: 900, countBaseline: 880))

    #expect(model.backfillFraction == nil)
    #expect(model.isCatchingUp)
}

// MARK: - Footer wording

/// The footer never renders the estimate as an exact denominator. "of about N"
/// concedes that Gmail documents `resultSizeEstimate` as approximate — the very
/// reason the bar is capped below 100%.
@Test func theFooterHedgesTheEstimateRatherThanStatingItExactly() {
    let sidebar = SidebarView(
        accountEmail: "a@example.com", unreadCount: 0, labels: [], pendingCount: 0,
        isCatchingUp: true,
        backfillProgress: .init(
            state: "listing", stored: 340, totalEstimate: 1_240, countBaseline: 0),
        selection: .inbox, onSelect: { _ in })

    #expect(sidebar.footerStatusText == "Getting your mail — 340 of about 1240")
}

/// Once the real count passes the estimate, the total is dropped rather than
/// shown as already exceeded.
@Test func theFooterDropsTheTotalOnceTheCountExceedsIt() {
    let sidebar = SidebarView(
        accountEmail: "a@example.com", unreadCount: 0, labels: [], pendingCount: 0,
        isCatchingUp: true,
        backfillProgress: .init(
            state: "listing", stored: 1_500, totalEstimate: 1_240, countBaseline: 0),
        selection: .inbox, onSelect: { _ in })

    #expect(sidebar.footerStatusText == "Getting your mail — 1500 so far")
}

/// An offline first launch explains itself instead of freezing on a progress
/// line. The auto-sync loop is deliberately silent about failures, so this is
/// the only place that can say so.
@Test func aStalledSyncSaysSoRatherThanShowingFrozenProgress() {
    let sidebar = SidebarView(
        accountEmail: "a@example.com", unreadCount: 0, labels: [], pendingCount: 0,
        isCatchingUp: true, isSyncStalled: true,
        backfillProgress: .init(
            state: "listing", stored: 340, totalEstimate: 1_240, countBaseline: 0),
        selection: .inbox, onSelect: { _ in })

    #expect(sidebar.footerStatusText == "Waiting for network…")
}

/// The pre-existing contract still holds: a settled mailbox says "All synced".
@Test func aSettledMailboxStillSaysAllSynced() {
    let sidebar = SidebarView(
        accountEmail: "a@example.com", unreadCount: 0, labels: [], pendingCount: 0,
        selection: .inbox, onSelect: { _ in })

    #expect(sidebar.footerStatusText == "All synced")
}

// MARK: - Inbox "not loaded yet"

/// `rows` starts empty, which is indistinguishable from a genuinely empty
/// mailbox — so the list needs a separate signal to stay quiet until the store
/// has actually answered.
@MainActor
@Test func theInboxKnowsItHasNotReadTheStoreYet() async throws {
    let db = try HudsonDatabase.inMemory()
    let inbox = InboxModel(database: db, account: "a@example.com")

    #expect(!inbox.hasLoaded)
}

// MARK: - Support

/// An `AppModel` over a connected, mid-backfill account — the state every
/// fraction assertion above starts from.
@MainActor
private func progressModel() async throws -> AppModel {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "a@example.com", clientID: "id", consentedAt: .now)
    let account = try #require(try await db.primaryAccount())
    return AppModel(database: db, account: account)
}

// MARK: - RootView boot precedence

/// **The regression test for the blocker an adversarial review caught.**
///
/// `bootPhase` had been reordered to give onboarding precedence, but `body`
/// still re-tested `model`/`onboarding` inline in the OLD order — and because
/// `bootPhase` was consumed only as the `.animation(value:)` key, nothing
/// failed loudly. The AI-key step was simply never mounted, `onboarding` stayed
/// non-nil forever (its only exit is a button on that unmounted screen), and
/// after a disconnect the stale screen resurfaced and could rebuild an
/// `AppModel` for the deleted account.
///
/// The state that matters is BOTH live at once: the account row exists and its
/// mail is already downloading, while the optional key step is still showing.
@Test func onboardingOutranksAReadyMailboxWhileBothAreLive() {
    #expect(
        RootView.resolveBootPhase(hasOnboarding: true, hasReadyMailbox: true) == .onboarding)
}

/// The rest of the truth table, so the precedence can't be "fixed" by
/// inverting it.
@Test func bootPhaseCoversEveryCombination() {
    #expect(
        RootView.resolveBootPhase(hasOnboarding: true, hasReadyMailbox: false) == .onboarding)
    #expect(
        RootView.resolveBootPhase(hasOnboarding: false, hasReadyMailbox: true) == .mailbox)
    #expect(
        RootView.resolveBootPhase(hasOnboarding: false, hasReadyMailbox: false) == .loading)
}
