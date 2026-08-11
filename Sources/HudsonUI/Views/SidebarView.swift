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

    public init(
        accountEmail: String?, unreadCount: Int, labels: [LabelRecord], pendingCount: Int,
        isSyncing: Bool = false, syncBanner: String? = nil,
        selection: Selection, onSelect: @escaping (Selection) -> Void,
        onSyncNow: @escaping () -> Void = {}, onSettings: @escaping () -> Void = {}
    ) {
        self.accountEmail = accountEmail
        self.unreadCount = unreadCount
        self.labels = labels
        self.pendingCount = pendingCount
        self.isSyncing = isSyncing
        self.syncBanner = syncBanner
        self.selection = selection
        self.onSelect = onSelect
        self.onSyncNow = onSyncNow
        self.onSettings = onSettings
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
        HStack(spacing: Metrics.unit * 2) {
            Text(footerStatusText)
                .font(Typography.ui(11))
                .foregroundStyle(syncBanner != nil ? Palette.danger : Palette.inkTertiary)
                .lineLimit(1)
            Spacer(minLength: Metrics.unit)
            syncNowButton
            // Non-functional placeholder — a settings scene lands in a later task.
            Button(action: onSettings) {
                Image(systemName: "gearshape")
                    .foregroundStyle(Palette.inkTertiary)
            }
            .buttonStyle(.plain)
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
    private var footerStatusText: String {
        if let syncBanner { return syncBanner }
        if isSyncing { return "Syncing…" }
        return pendingCount > 0 ? "\(pendingCount) pending" : "All synced"
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
        .buttonStyle(.plain)
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
