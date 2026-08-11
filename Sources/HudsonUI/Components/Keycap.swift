import SwiftUI

/// A single keyboard-shortcut glyph, e.g. the "⌘" or "K" in "⌘K". Composed in
/// a row by callers that want to show a full chord (`Keycap("⌘") Keycap("K")`).
public struct Keycap: View {
    private let label: String

    public init(_ label: String) {
        self.label = label
    }

    public var body: some View {
        Text(label)
            .font(Typography.ui(11, .medium))
            .foregroundStyle(Palette.inkSecondary)
            // 2×5 padding is the Pencil spec value, not derived from `unit`.
            .padding(.vertical, 2)
            .padding(.horizontal, 5)
            .background(Palette.bgSunken)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusSmall))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radiusSmall)
                    .strokeBorder(Palette.border, lineWidth: 1)
            )
    }
}

#Preview {
    HStack(spacing: 4) {
        Keycap("⌘")
        Keycap("K")
        Keycap("E")
        Keycap("↵")
    }
    .padding()
    .background(Palette.bgApp)
}
