import SwiftUI

/// A transient floating confirmation — e.g. "Archived · Undo" after a
/// triage action. The caller owns show/hide timing; this view is purely
/// presentational.
public struct Toast: View {
    private let text: String

    public init(text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(Typography.ui(13, .medium))
            .foregroundStyle(Palette.ink)
            // Padding not spec'd explicitly, derived from `unit`.
            .padding(.horizontal, Metrics.unit * 3)
            .padding(.vertical, Metrics.unit * 2)
            .background(Palette.bgSunken)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusMedium))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radiusMedium)
                    .strokeBorder(Palette.borderStrong, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }
}

#Preview {
    Toast(text: "Archived · Undo")
        .padding()
        .background(Palette.bgApp)
}
