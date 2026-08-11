import SwiftUI
import Testing
@testable import HudsonUI

@MainActor
@Test func accentTokenResolvesToPencilGreen() {
    let resolved = Palette.accent.resolve(in: EnvironmentValues())
    #expect(abs(Double(resolved.red)   - 0x8F/255.0) < 0.01)
    #expect(abs(Double(resolved.green) - 0xB5/255.0) < 0.01)
    #expect(abs(Double(resolved.blue)  - 0xA5/255.0) < 0.01)
}

@Test func metricsMatchPencilRadii() {
    #expect(Metrics.radiusLarge == 12)
    #expect(Metrics.radiusMedium == 7)
    #expect(Metrics.radiusSmall == 4)
}

@MainActor
@Test func atomsComposeIntoAHostingView() {
    let stack = VStack {
        Keycap("⌘K")
        Chip(text: "Promotions", role: .category)
        InboxTab(title: "Important", count: 12, isActive: true, action: {})
        EmailRow(row: .init(fromSummary: "Ada Lovelace", subject: "Re: Analytical Engine",
                            snippet: "The numbers are ready.", timeText: "9:41",
                            hasAttachment: true, category: "updates", unread: true),
                 isSelected: true, isUnread: true)
    }
    let host = NSHostingView(rootView: stack)
    host.layout()
    #expect(host.fittingSize.width > 0)
    #expect(host.fittingSize.height > 0)
}
