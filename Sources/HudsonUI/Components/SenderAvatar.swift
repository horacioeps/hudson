import SwiftUI

/// The 28pt rounded-square initial badge each message header opens with
/// (Pencil "Thread (Expanded)" → Msg Header → Avatar).
///
/// The design gives each participant a different fill (`#B08A5A` for one
/// sender, `#3E6152` for "you"), so the color has to be derived from the
/// sender rather than fixed. It's a stable hash of the address: the same
/// person is the same color in every thread and across launches, which is
/// what makes the badge scannable at all.
struct SenderAvatar: View {
    let fromLine: String
    /// Messages the account owner sent get the accent-derived swatch, the way
    /// the design tints "You" differently from the other participants.
    var isYou: Bool = false

    /// Muted, dark-ground-friendly fills — chosen around the two the design
    /// specifies so a thread's participants stay distinguishable without any
    /// of them fighting the UI for attention.
    private static let swatches: [Color] = [
        Color(hex: 0xB08A5A), Color(hex: 0x6E7E9B), Color(hex: 0x8C6A7D),
        Color(hex: 0x7B8B5A), Color(hex: 0xA8735A), Color(hex: 0x5F8080),
    ]
    private static let youSwatch = Color(hex: 0x3E6152)

    private var fill: Color {
        guard !isYou else { return Self.youSwatch }
        let key = SenderInfo.address(fromLine: fromLine).lowercased()
        // A plain additive hash rather than `hashValue`: Swift seeds the
        // latter per process, so it would repaint everyone on every launch.
        let sum = key.unicodeScalars.reduce(0) { ($0 &+ Int($1.value)) % 4096 }
        return Self.swatches[sum % Self.swatches.count]
    }

    var body: some View {
        RoundedRectangle(cornerRadius: Metrics.radiusMedium)
            .fill(fill)
            .frame(width: 28, height: 28)
            .overlay(
                Text(SenderInfo.initials(fromLine: fromLine))
                    .font(Typography.ui(12, .bold))
                    .foregroundStyle(.white)
            )
    }
}
