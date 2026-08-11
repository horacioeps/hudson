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
    private let selection: Selection
    private let onSelect: (Selection) -> Void
    private let onSettings: () -> Void

    public init(
        accountEmail: String?, unreadCount: Int, labels: [LabelRecord], pendingCount: Int,
        selection: Selection, onSelect: @escaping (Selection) -> Void,
        onSettings: @escaping () -> Void = {}
    ) {
        self.accountEmail = accountEmail
        self.unreadCount = unreadCount
        self.labels = labels
        self.pendingCount = pendingCount
        self.selection = selection
        self.onSelect = onSelect
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
        .frame(width: Metrics.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
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
            Text(pendingCount > 0 ? "\(pendingCount) pending" : "All synced")
                .font(Typography.ui(11))
                .foregroundStyle(Palette.inkTertiary)
                .lineLimit(1)
            Spacer(minLength: Metrics.unit)
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
