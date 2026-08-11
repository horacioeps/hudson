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
    private let row: EmailRowData
    private let isSelected: Bool
    private let isUnread: Bool

    public init(row: EmailRowData, isSelected: Bool, isUnread: Bool) {
        self.row = row
        self.isSelected = isSelected
        self.isUnread = isUnread
    }

    public var body: some View {
        HStack(spacing: Metrics.unit * 2) {
            // Leading 2pt accent bar on selection; a clear spacer of the same
            // width keeps unselected rows aligned to the same content start.
            Rectangle()
                .fill(isSelected ? Palette.accent : .clear)
                .frame(width: 2)

            // 6pt unread dot; hidden (but space-reserved) once read.
            Circle()
                .fill(isUnread ? Palette.accent : .clear)
                .frame(width: 6, height: 6)

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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(height: 72)
        .background(isSelected ? Palette.bgSelected : .clear)
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
