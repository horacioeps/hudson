import SwiftUI

/// Plain display data for one `EmailRow`. Intentionally has zero Store
/// dependency — the message-list view maps `ThreadRow` (or similar) into this
/// struct, so the component stays testable and previewable on its own.
public struct EmailRowData: Sendable, Equatable {
    public let fromSummary: String
    public let subject: String
    public let snippet: String
    public let timeText: String
    public let hasAttachment: Bool
    /// Category label (e.g. "updates"); empty string hides the trailing chip.
    public let category: String
    public let unread: Bool

    public init(
        fromSummary: String, subject: String, snippet: String, timeText: String,
        hasAttachment: Bool, category: String, unread: Bool
    ) {
        self.fromSummary = fromSummary
        self.subject = subject
        self.snippet = snippet
        self.timeText = timeText
        self.hasAttachment = hasAttachment
        self.category = category
        self.unread = unread
    }
}

/// One row in the message list: sender/time, subject, and a truncated
/// snippet. `isSelected` and `isUnread` are passed separately from `row`
/// because they're transient UI state a list can override optimistically
/// (e.g. instant "mark as read") ahead of the store round-trip.
public struct EmailRow: View {
    /// The row's fixed height, plus the insets its content sits in. These are
    /// `internal` rather than private because `InboxListView` positions the
    /// travelling selection bar from this arithmetic instead of measuring a
    /// row: inside a `LazyVStack` the row the bar is travelling away from may
    /// already have been discarded, and an unrealized row has no geometry.
    static let height: CGFloat = 72
    static let horizontalInset: CGFloat = 12
    static let verticalInset: CGFloat = 8
    /// Width of the leading selection bar `InboxListView` draws, matching the
    /// clear gutter every row reserves for it below.
    static let selectionBarWidth: CGFloat = 2

    private let row: EmailRowData
    private let isSelected: Bool
    private let isUnread: Bool
    @State private var isHovered = false

    public init(row: EmailRowData, isSelected: Bool, isUnread: Bool) {
        self.row = row
        self.isSelected = isSelected
        self.isUnread = isUnread
    }

    public var body: some View {
        HStack(spacing: Metrics.unit * 2) {
            // A clear gutter the width of the selection bar, which the list
            // draws over the row rather than inside it — one bar that slides
            // between rows reads as a moving caret, where a per-row fill can
            // only blink out of one row and into another.
            Color.clear
                .frame(width: Self.selectionBarWidth)

            // 6pt unread dot; space stays reserved once read. Only the dot
            // animates: SwiftUI cannot interpolate the `Font.Weight` change
            // below it, so the weights snap under cover of this 180ms — which
            // is where the eye already is.
            //
            // And only in the read direction. Opening a thread is the user's
            // doing; a thread GAINING an unread message is a sync pass writing
            // into a row that is already on screen, and this surface never
            // animates an async arrival (see the `ForEach`'s
            // `insertion: .identity` in `InboxListView`).
            Circle()
                .fill(Palette.accent)
                .frame(width: 6, height: 6)
                .opacity(isUnread ? 1 : 0)
                .scaleEffect(isUnread ? 1 : 0.5)
                .animation(isUnread ? nil : Motion.collapse, value: isUnread)

            VStack(alignment: .leading, spacing: Metrics.unit) {
                HStack {
                    Text(row.fromSummary)
                        .font(Typography.ui(13, isUnread ? .semibold : .medium))
                        .foregroundStyle(Palette.ink)
                    Spacer(minLength: Metrics.unit)
                    Text(row.timeText)
                        .font(Typography.ui(11))
                        .foregroundStyle(Palette.inkTertiary)
                }

                Text(row.subject)
                    .font(Typography.ui(13, isUnread ? .semibold : .regular))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)

                HStack(spacing: Metrics.unit) {
                    Text(row.snippet)
                        .font(Typography.ui(12))
                        .foregroundStyle(Palette.inkSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if row.hasAttachment {
                        Image(systemName: "paperclip")
                            .font(Typography.ui(11))
                            .foregroundStyle(Palette.inkTertiary)
                    }
                    if !row.category.isEmpty {
                        Chip(text: row.category, role: .category)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, Self.horizontalInset)
        .padding(.vertical, Self.verticalInset)
        .frame(height: Self.height)
        .background {
            // Both animations live on the fill, not on the row, so neither can
            // catch an unrelated change — a sync-driven snippet edit or the
            // unread weight swap — in an animated transaction.
            Rectangle()
                .fill(backgroundColor)
                // The tint cross-fades rather than travelling with the
                // selection bar: a moving tint would smear across every row
                // between the old selection and the new one.
                .animation(Motion.crossfade, value: isSelected)
        }
        // The hover tint snaps — the only hover in the app that does not fade.
        // AppKit delivers enter/exit when a view moves under a STATIONARY
        // pointer, so scrolling this list hovers every row that passes the
        // cursor, several per frame. Faded, that leaves a trail of half-lit
        // rows behind the scroll (the `hoverOut` curve is longer than the gap
        // between two rows crossing the pointer) and hangs an animation on each
        // of them, inside the one view with a 16ms budget. Snapped, exactly one
        // row is ever lit: the one under the pointer.
        .onHover { isHovered = $0 }
    }

    /// A selected row keeps its tint under the cursor — lightening it would
    /// read as the selection being about to change.
    private var backgroundColor: Color {
        if isSelected { return Palette.bgSelected }
        return isHovered ? Palette.bgHover : .clear
    }
}

#Preview {
    EmailRow(
        row: EmailRowData(
            fromSummary: "Ada Lovelace", subject: "Re: Analytical Engine",
            snippet: "The numbers are ready.", timeText: "9:41",
            hasAttachment: true, category: "updates", unread: true),
        isSelected: true, isUnread: true)
    .frame(width: Metrics.listWidth)
    .background(Palette.bgApp)
}
