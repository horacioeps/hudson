import SwiftUI

/// One tab in the inbox's split-view header (e.g. "Important", "Other").
/// Active state is shown with `ink` text plus a 2pt accent indicator bar,
/// rather than a filled pill, so the tab strip stays visually quiet.
public struct InboxTab: View {
    private let title: String
    private let count: Int
    private let isActive: Bool
    private let indicatorNamespace: Namespace.ID?
    private let action: () -> Void

    /// A tab rendered outside a strip matches the indicator against its own
    /// namespace, which is a no-op — so the component still draws correctly
    /// on its own, and only a strip that supplies `indicatorNamespace` gets
    /// the bar sliding between tabs.
    @Namespace private var ownNamespace

    /// The one geometry id every tab's indicator shares. Because exactly one
    /// tab renders it at a time, SwiftUI reads the swap as the same bar
    /// moving, and interpolates its x-origin and its width — "Primary 12" and
    /// "Other" are different widths, so it stretches as it travels.
    private static let indicatorID = "inbox-tab-indicator"

    public init(
        title: String, count: Int, isActive: Bool,
        indicatorNamespace: Namespace.ID? = nil, action: @escaping () -> Void
    ) {
        self.title = title
        self.count = count
        self.isActive = isActive
        self.indicatorNamespace = indicatorNamespace
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            VStack(spacing: Metrics.unit) {
                HStack(spacing: Metrics.unit) {
                    Text(title)
                    if count > 0 {
                        Text("\(count)")
                            // Tabular figures because `refreshTabCounts` re-derives
                            // this on every rows emit: a proportional "1" would
                            // resize the tab, and shove its neighbours, on every
                            // archive. With the width pinned, rolling the digit is
                            // a glyph-level change with no reflow behind it —
                            // which is what makes it safe on an async value.
                            .font(Typography.ui(12, .semibold).monospacedDigit())
                            .contentTransition(.numericText(countsDown: true))
                            .animation(Motion.crossfade, value: count)
                    }
                }
                .font(Typography.ui(12, .semibold))
                .foregroundStyle(isActive ? Palette.ink : Palette.inkTertiary)

                // 2pt accent indicator when active; a clear slot of the same
                // height keeps inactive tabs aligned to the same baseline.
                Color.clear
                    .frame(height: 2)
                    .overlay {
                        if isActive {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Palette.accent)
                                .matchedGeometryEffect(
                                    id: Self.indicatorID, in: indicatorNamespace ?? ownNamespace)
                        }
                    }
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
