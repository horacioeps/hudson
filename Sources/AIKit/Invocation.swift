import Foundation

/// A token proving that ONE explicit user action (a CLI verb or a UI control)
/// asked for ONE AI feature to run. This is the load-bearing half of Hudson's
/// "no background AI egress, ever" guarantee (spec §8): `EgressGuard.run`
/// requires an `Invocation`, and the ONLY way to obtain one is the
/// `userInvoked(_:)` factory. The initializer is `private`, so no background
/// task, timer, scroll handler, or sync callback can fabricate one — the
/// absence of an ambient constructor is a COMPILE-TIME guarantee, not a
/// convention a reviewer must police.
///
/// The name `userInvoked` is chosen so every call site reads as an explicit
/// user action (`Invocation.userInvoked(.summarize)`); a reviewer scanning for
/// egress can grep this one factory and see exactly which user actions reach
/// the network.
public struct Invocation: Sendable {
    /// Which feature this user action invoked — `EgressGuard` reads it to look
    /// up that feature's per-feature opt-in row.
    public let feature: AIFeature

    /// Private by design: see the type doc. Nothing outside this file can call
    /// it, and the only thing inside this file that does is `userInvoked`.
    private init(feature: AIFeature) {
        self.feature = feature
    }

    /// The sole way to mint an `Invocation`. Call this at — and only at — an
    /// explicit user-action boundary (a CLI subcommand's `run()`, a UI button
    /// handler). Passing the returned token to `EgressGuard.run` is what lets
    /// content leave the machine; holding one is equivalent to a user having
    /// pressed the button.
    public static func userInvoked(_ feature: AIFeature) -> Invocation {
        Invocation(feature: feature)
    }
}
