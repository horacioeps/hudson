import Foundation
import Store

/// The SINGLE internal choke point through which mail content may leave the
/// machine, and the ONLY code in the entire codebase that calls
/// `provider.stream` (spec §8; architecture pillar 2). Every feature module
/// (summarize, draft, ask-inbox) obtains its stream via `run(_:for:)` — none
/// of them holds a `provider` reference or calls `stream` directly. Combined
/// with `Invocation`'s private init, this makes "no background AI egress,
/// ever" a type-level property: egress is reachable only from an explicit
/// user action (the `Invocation`) AND a per-feature opt-in row.
///
/// It is an `actor` because it is network-driven shared state (Swift 6 strict
/// concurrency, spec §4.6): the provider and database handles are serialized
/// through it.
public actor EgressGuard {
    private let provider: any LLMProvider
    private let database: HudsonDatabase
    private let account: String

    public init(provider: any LLMProvider, database: HudsonDatabase, account: String) {
        self.provider = provider
        self.database = database
        self.account = account
    }

    /// The one egressing method. Verifies the invoked feature is opted in —
    /// `ai_config.opt_in == true` for `invocation.feature` — and only then
    /// forwards to the provider. A missing row (feature never configured) or
    /// an explicit `opt_in = false` throws `AIError.notOptedIn` BEFORE any
    /// network call, so the opt-in gate is fail-closed.
    ///
    /// The `Invocation` parameter is non-negotiable: without one the compiler
    /// won't let a caller reach this method, and one can be minted only from an
    /// explicit user action. The returned stream is the provider's live
    /// stream, consumed by exactly the feature module that called this.
    public func run(
        _ request: LLMRequest, for invocation: Invocation
    ) async throws -> AsyncThrowingStream<LLMEvent, Error> {
        let feature = invocation.feature
        let config = try await database.aiConfig(feature: feature.rawValue, account: account)
        guard config?.optIn == true else {
            throw AIError.notOptedIn(feature)
        }
        return provider.stream(request)
    }
}
