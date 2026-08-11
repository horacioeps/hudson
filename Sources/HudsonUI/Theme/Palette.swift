import SwiftUI

/// Hudson's color tokens, lifted verbatim from the Pencil Design System frame.
/// One name per token — views reference `Palette.accent`, never a raw hex — so
/// a future theme change is one edit here.
public enum Palette {
    public static let bgApp        = Color(hex: 0x1C1C1A)
    public static let bgSurface    = Color(hex: 0x242422)
    public static let bgSunken     = Color(hex: 0x171716)
    public static let bgHover      = Color(hex: 0x2B2B28)
    public static let bgSelected   = Color(hex: 0x2C3530)
    public static let border       = Color(hex: 0x32322E)
    public static let borderStrong = Color(hex: 0x474640)
    public static let accent       = Color(hex: 0x8FB5A5)
    public static let accentInk    = Color(hex: 0x16211D)
    public static let accentSoft   = Color(hex: 0x2A362F)
    public static let ink          = Color(hex: 0xECEAE4)
    public static let inkSecondary = Color(hex: 0xA29E95)
    public static let inkTertiary  = Color(hex: 0x6E6B64)
    public static let aiBg         = Color(hex: 0x2E2A20)
    public static let aiInk        = Color(hex: 0xC7AC72)
    public static let danger       = Color(hex: 0xD07A62)
    public static let warnBg       = Color(hex: 0x332E21)
}

extension Color {
    /// 0xRRGGBB → sRGB Color. Kept internal to the theme; views use named tokens.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255,
            opacity: 1)
    }
}
