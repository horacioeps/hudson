import SwiftUI

/// One tab in the inbox's split-view header (e.g. "Important", "Other").
/// Active state is shown with `ink` text plus a 2pt accent indicator bar,
/// rather than a filled pill, so the tab strip stays visually quiet.
public struct InboxTab: View {
    private let title: String
    private let count: Int
    private let isActive: Bool
    private let action: () -> Void

    public init(title: String, count: Int, isActive: Bool, action: @escaping () -> Void) {
        self.title = title
        self.count = count
        self.isActive = isActive
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            VStack(spacing: Metrics.unit) {
                HStack(spacing: Metrics.unit) {
                    Text(title)
                    if count > 0 {
                        Text("\(count)")
                    }
                }
                .font(Typography.ui(12, .semibold))
                .foregroundStyle(isActive ? Palette.ink : Palette.inkTertiary)

                // 2pt accent indicator when active; a clear spacer of the same
                // height keeps inactive tabs aligned to the same baseline.
                RoundedRectangle(cornerRadius: 1)
                    .fill(isActive ? Palette.accent : .clear)
                    .frame(height: 2)
            }
            // Padding not spec'd explicitly, derived from `unit`.
            .padding(.horizontal, Metrics.unit * 2)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    HStack {
        InboxTab(title: "Important", count: 12, isActive: true, action: {})
        InboxTab(title: "Other", count: 3, isActive: false, action: {})
    }
    .padding()
    .background(Palette.bgApp)
}
