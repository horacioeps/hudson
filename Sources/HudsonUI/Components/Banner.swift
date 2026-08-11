import SwiftUI

/// Which state a `Banner` communicates. Each role maps to a fixed
/// (foreground, background) pair from `Palette`.
public enum BannerRole {
    case warn
    case error

    var foreground: Color {
        switch self {
        case .warn:  Palette.aiInk
        case .error: Palette.danger
        }
    }
}

/// A full-width strip for app-level state — offline, sync errors — pinned
/// above the content it affects.
public struct Banner: View {
    private let text: String
    private let role: BannerRole

    public init(text: String, role: BannerRole) {
        self.text = text
        self.role = role
    }

    public var body: some View {
        Text(text)
            .font(Typography.ui(12, .medium))
            .foregroundStyle(role.foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Padding not spec'd explicitly, derived from `unit`.
            .padding(.horizontal, Metrics.unit * 3)
            .padding(.vertical, Metrics.unit * 2)
            .background(Palette.warnBg)
    }
}

#Preview {
    VStack(spacing: 0) {
        Banner(text: "You're offline — showing the last synced inbox.", role: .warn)
        Banner(text: "Sync failed — check your connection.", role: .error)
    }
    .background(Palette.bgApp)
}
