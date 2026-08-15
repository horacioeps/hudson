import Store
import SwiftUI

/// The left navigation rail: account identity, the four fixed mailboxes,
/// user labels, and a sync-status footer. Purely presentational — every
/// value arrives via the initializer and every tap goes through `onSelect`/
/// `onSettings`, so this view owns no Store calls (the real wiring, reading
/// `AppModel`/`InboxModel`/`labels(account:)`, is Task 11's job).
public struct SidebarView: View {
    /// Which single row is highlighted. A label uses its own `id` (not
    /// `name`) so a rename can't silently drop the current selection.
    public enum Selection: Hashable, Sendable {
        case inbox, starred, snoozed, sent
        case label(String)
    }

    private let accountEmail: String?
    private let unreadCount: Int
    private let labels: [LabelRecord]
    private let pendingCount: Int
    /// True while `AppModel.syncNow()` has a pass in flight — disables the
    /// footer's "Sync now" button (no double-tap into an overlapping pass;
    /// `AppModel.syncNow()` itself already guards this too, but disabling
    /// the button is the visible half of that guard) and swaps the status
    /// text to "Syncing…".
    private let isSyncing: Bool
    /// True while the initial backfill/body-hydration is still catching up —
    /// drives the footer's "Getting your mail…" line (a fresh account isn't
    /// told "All synced" while bodies are still streaming in).
    private let isCatchingUp: Bool
    /// `AppModel.isSyncStalled` — the last pass threw. Distinguishes "still
    /// downloading" from "cannot reach Gmail", so an offline first launch
    /// explains itself instead of showing a frozen progress line.
    private let isSyncStalled: Bool
    /// `AppModel.backfillFraction` — `nil` whenever there is no measured total
    /// to draw, which is also the signal to hide the bar (see
    /// `showsProgressTrack`).
    private let backfillFraction: Double?
    /// `AppModel.backfillProgress` — the raw counts behind `downloadStatusText`.
    private let backfillProgress: BackfillProgress?
    /// `AppModel.syncBanner` — non-`nil` for "no account connected" or "the
    /// last pass failed". Surfaced right next to the button that would fix
    /// it (in place of the pending-count text) rather than only at
    /// `RootView`'s top-pinned strip, so the reason a tap didn't do anything
    /// obvious is never more than a glance away.
    private let syncBanner: String?
    private let selection: Selection
    private let onSelect: (Selection) -> Void
    private let onSyncNow: () -> Void
    private let onSettings: () -> Void
    private let onCompose: () -> Void

    public init(
        accountEmail: String?, unreadCount: Int, labels: [LabelRecord], pendingCount: Int,
        isSyncing: Bool = false, isCatchingUp: Bool = false, isSyncStalled: Bool = false,
        backfillFraction: Double? = nil, backfillProgress: BackfillProgress? = nil,
        syncBanner: String? = nil,
        selection: Selection, onSelect: @escaping (Selection) -> Void,
        onSyncNow: @escaping () -> Void = {}, onSettings: @escaping () -> Void = {},
        onCompose: @escaping () -> Void = {}
    ) {
        self.accountEmail = accountEmail
        self.unreadCount = unreadCount
        self.labels = labels
        self.pendingCount = pendingCount
        self.isSyncing = isSyncing
        self.isCatchingUp = isCatchingUp
        self.isSyncStalled = isSyncStalled
        self.backfillFraction = backfillFraction
        self.backfillProgress = backfillProgress
        self.syncBanner = syncBanner
        self.selection = selection
        self.onSelect = onSelect
        self.onSyncNow = onSyncNow
        self.onSettings = onSettings
        self.onCompose = onCompose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Reserves the window's traffic-light inset — the window runs
            // `.hiddenTitleBar`, so nothing else in this view draws that strip.
            Color.clear.frame(height: 28)

            Text(accountEmail ?? "Hudson")
                .font(Typography.ui(13, .semibold))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, Metrics.unit * 3)
                .padding(.bottom, Metrics.unit * 3)

            // The primary "start a new email" affordance (also ⌘N). Was
            // missing — you could reply but not compose from scratch.
            PrimaryButton(title: "New message", action: onCompose)
                .padding(.horizontal, Metrics.unit * 3)
                .padding(.bottom, Metrics.unit * 4)

            primaryNav
                .padding(.horizontal, Metrics.unit * 2)

            if !labels.isEmpty {
                sectionHeader("LABELS")
                    .padding(.top, Metrics.unit * 5)
                    .padding(.bottom, Metrics.unit)

                labelList
                    .padding(.horizontal, Metrics.unit * 2)
            }

            Spacer(minLength: 0)

            footer
        }
        // No hard width here anymore — RootView gives the sidebar column a
        // min/ideal/max via `.navigationSplitViewColumnWidth` so its divider
        // stays draggable (see the reading-pane resize fix).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Palette.bgSunken)
    }

    private var primaryNav: some View {
        VStack(spacing: 2) {
            SidebarItem(
                icon: "tray", title: "Inbox", count: unreadCount > 0 ? unreadCount : nil,
                isSelected: selection == .inbox, action: { onSelect(.inbox) })
            SidebarItem(
                icon: "star", title: "Starred", isSelected: selection == .starred,
                action: { onSelect(.starred) })
            SidebarItem(
                icon: "clock", title: "Snoozed", isSelected: selection == .snoozed,
                action: { onSelect(.snoozed) })
            SidebarItem(
                icon: "paperplane", title: "Sent", isSelected: selection == .sent,
                action: { onSelect(.sent) })
        }
    }

    private var labelList: some View {
        VStack(spacing: 2) {
            ForEach(labels, id: \.id) { label in
                SidebarItem(
                    icon: "tag", title: label.name, isSelected: selection == .label(label.id),
                    action: { onSelect(.label(label.id)) })
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(Typography.ui(11, .semibold))
            .foregroundStyle(Palette.inkTertiary)
            .tracking(0.6)
            .padding(.horizontal, Metrics.unit * 3)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Metrics.unit) {
            HStack(spacing: Metrics.unit * 2) {
                // The Hudson wordmark — the app's mark in the bottom bar.
                Text("Hudson")
                    .font(Typography.serif(15, .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: Metrics.unit)
                syncNowButton
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                        .foregroundStyle(Palette.inkTertiary)
                }
                .buttonStyle(.pressable)
            }
            // Sync status as a quiet subtitle under the wordmark. This line
            // changes its WORD, all day, every time a pass starts or ends — so
            // it dissolves in place (the same `.contentTransition(.opacity)`
            // every other in-place text swap in the app uses) rather than
            // giving each wording its own identity: two strings co-mounted in
            // one 13pt slot draw over each other as a smear, and `Motion.reveal`
            // would push the incoming one 6pt up into the wordmark, since
            // nothing here clips. The fixed height keeps the footer and the
            // divider above it still regardless.
            Text(footerStatusText)
                .font(Typography.ui(10))
                .foregroundStyle(syncBanner != nil ? Palette.danger : Palette.inkTertiary)
                .lineLimit(1)
                .contentTransition(.opacity)
                .frame(height: 13, alignment: .leading)
                .animation(Motion.crossfade, value: footerStatusText)
            // The download bar's slot is reserved PERMANENTLY rather than
            // inserted when a backfill starts. The status line above already
            // pins its own height for exactly this reason — so the divider at
            // the top of the footer never moves — and animating the footer's
            // height would shift that divider, and everything above it, at the
            // one moment the app is trying to look composed: first launch.
            // The cost is a few points of quiet sidebar chrome forever; the
            // alternative is a visible jolt twice per fresh account.
            ProgressTrack(fraction: backfillFraction)
                .opacity(showsProgressTrack ? 1 : 0)
                .animation(Motion.crossfade, value: showsProgressTrack)
        }
        .padding(.horizontal, Metrics.unit * 3)
        .padding(.vertical, Metrics.unit * 3)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.border).frame(height: 1)
        }
    }

    /// The footer's single line of sync status, in priority order: a
    /// `syncBanner` (something needs the user's attention — no account, or
    /// the last pass failed) beats `isSyncing` (a pass is in flight) beats
    /// the ordinary pending-mutations count. One line, one truth, rather
    /// than three separately-toggled pieces of footer chrome.
    var footerStatusText: String {
        if let syncBanner { return syncBanner }
        // Stalled outranks "Syncing…"/"Getting your mail…": a frozen progress
        // line with no explanation is the worst of the options, and the
        // auto-sync loop is deliberately silent otherwise (it never sets
        // `syncBanner`), so this is the only place an offline first launch can
        // say so.
        if isSyncStalled { return "Waiting for network…" }
        if isSyncing { return "Syncing…" }
        if isCatchingUp { return downloadStatusText }
        return pendingCount > 0 ? "\(pendingCount) pending" : "All synced"
    }

    /// The catching-up wording, which reports counts only when they mean
    /// something.
    ///
    /// Note what this deliberately never renders: "340 of 1,240". The total is
    /// Gmail's `resultSizeEstimate`, which Google documents as approximate —
    /// the whole reason `AppModel` caps the bar below 100% — so stating it as
    /// an exact denominator would claim a precision the number does not have.
    /// "about 1,240" concedes the estimate; once the real count passes it, the
    /// total is dropped entirely rather than shown as already exceeded.
    private var downloadStatusText: String {
        // `isSeeded` is required as well as `isFirstDownload`: between a
        // restart clearing the seeds and the next first page re-seeding them,
        // `stored` already reflects a full mailbox, so quoting it would report
        // a count that has nothing to do with this run's progress.
        guard let progress = backfillProgress, progress.isRunning,
              progress.isSeeded, progress.isFirstDownload, progress.stored > 0
        else { return "Getting your mail…" }
        guard let total = progress.totalEstimate, total > 0, progress.stored <= total else {
            return "Getting your mail — \(progress.stored) so far"
        }
        return "Getting your mail — \(progress.stored) of about \(total)"
    }

    /// The bar shows only when there is a measured fraction to draw AND we are
    /// genuinely catching up. A re-list of mail already on disk, an unknown
    /// total, a stalled network, and the demo mailbox all fall through to the
    /// status line with an empty track.
    private var showsProgressTrack: Bool {
        isCatchingUp && !isSyncStalled && backfillFraction != nil
    }

    /// A small text button (matching this footer's own compact 11pt scale,
    /// not the app-wide `PrimaryButton`/`QuietButton` — those are sized for
    /// a sheet's footer, not a narrow sidebar strip) that fires
    /// `AppModel.syncNow()` via `onSyncNow`. Disabled while `isSyncing` so a
    /// double-click can't queue two overlapping passes.
    private var syncNowButton: some View {
        Button(action: onSyncNow) {
            Text("Sync now")
                .font(Typography.ui(11, .medium))
                .foregroundStyle(isSyncing ? Palette.inkTertiary : Palette.accent)
        }
        .buttonStyle(.pressable)
        .disabled(isSyncing)
    }
}

#Preview {
    // `LabelRecord` has no public initializer (Store's Task 3 read type is
    // built only from a query row), so the preview shows the labels-less
    // shape; the render smoke test exercises the real `LABELS` section
    // against seeded demo data instead.
    SidebarView(
        accountEmail: "you@hudson.app", unreadCount: 12, labels: [], pendingCount: 0,
        selection: .inbox, onSelect: { _ in })
        .frame(height: 600)
}
