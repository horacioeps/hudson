import SwiftUI

/// One row in the left sidebar — a mailbox or label with an optional unread
/// count. `icon` is an SF Symbol name; the whole row is the hit target.
public struct SidebarItem: View {
    private let icon: String
    private let title: String
    private let count: Int?
    private let isSelected: Bool
    private let action: () -> Void
    @State private var isHovering = false

    public init(
        icon: String, title: String, count: Int? = nil, isSelected: Bool,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.title = title
        self.count = count
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.unit * 2) {
                Image(systemName: icon)
                    // Icon glyph box; not spec'd explicitly, derived as 4×unit.
                    .frame(width: Metrics.unit * 4, height: Metrics.unit * 4)
                Text(title)
                    .font(Typography.ui(13, .medium))
                Spacer(minLength: 0)
                if let count {
                    Text("\(count)")
                        .font(Typography.ui(11, .medium))
                        .foregroundStyle(Palette.inkTertiary)
                }
            }
            .foregroundStyle(isSelected ? Palette.ink : Palette.inkSecondary)
            // Padding not spec'd explicitly, derived from `unit`.
            .padding(.horizontal, Metrics.unit * 3)
            .padding(.vertical, Metrics.unit * 2)
            .background(isSelected ? Palette.accentSoft : (isHovering ? Palette.bgHover : .clear))
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusMedium))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

#Preview {
    VStack(spacing: 2) {
        SidebarItem(icon: "tray", title: "Inbox", count: 12, isSelected: true, action: {})
        SidebarItem(icon: "star", title: "Starred", isSelected: false, action: {})
    }
    .frame(width: Metrics.sidebarWidth)
    .padding()
    .background(Palette.bgApp)
}
