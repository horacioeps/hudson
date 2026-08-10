/// GmailKit is Hudson's typed Gmail REST client: OAuth, token storage,
/// quota-aware transport, and API models. It knows nothing about persistence
/// or UI — see `docs/superpowers/specs/2026-08-10-hudson-foundation-design.md` §2.
public enum GmailKit {
    /// The single OAuth scope Hudson requests (spec §6.2).
    public static let oauthScope = "https://www.googleapis.com/auth/gmail.modify"
}
