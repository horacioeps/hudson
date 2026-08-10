import SwiftUI

/// Visual treatment for a `Chip`. Each role maps to a fixed (foreground,
/// background) pair from `Palette` — never a raw color — so new chip uses
/// stay on-token.
public enum ChipRole {
    case neutral
    case accent
    case ai
    case category

    var foreground: Color {
        switch self {
        case .neutral:  Palette.inkSecondary
        case .accent:   Palette.accentInk
        case .ai:       Palette.aiInk
        case .category: Palette.inkSecondary
        }
    }

    var background: Color {
        switch self {
        case .neutral:  Palette.bgHover
        case .accent:   Palette.accent
        case .ai:       Palette.aiBg
        case .category: Palette.accentSoft
        }
    }
}

/// A small labeled pill used for categories, AI tags, and inline status —
/// e.g. the "updates" tag on an `EmailRow`.
public struct Chip: View {
    private let text: String
    private let role: ChipRole

    public init(text: String, role: ChipRole) {
        self.text = text
        self.role = role
    }

    public var body: some View {
        Text(text)
            .font(Typography.ui(11, .medium))
            .foregroundStyle(role.foreground)
            // 2×6 padding is the Pencil spec value, not derived from `unit`.
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .background(role.background)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusSmall))
    }
}

#Preview {
    HStack {
        Chip(text: "Neutral", role: .neutral)
        Chip(text: "Accent", role: .accent)
        Chip(text: "AI", role: .ai)
        Chip(text: "Promotions", role: .category)
    }
    .padding()
    .background(Palette.bgApp)
}
