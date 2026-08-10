# Hudson — Seamless Sharing & Distribution (decision)

**Date:** 2026-08-10
**Source:** 5-agent ultracode workflow (Google-auth policy, Apple distribution, AI-key seam, foundation-code impact — all web-verified) + user's stated constraints (privacy #1, free, already pays Apple dev fee).
**Status:** Locked direction. This is a UI/distribution-phase concern (after M7); three items must be *decided now* to avoid building the wrong onboarding/CI.

## Decision: the HYBRID model

**Default path (one-click, for friends):** a single **shared, published-but-unverified Desktop OAuth client** bundled in Hudson. A friend installs the notarized DMG → clicks "Sign in with Google" → clicks past ONE "Google hasn't verified this app → Advanced → Continue" screen → is triaging mail. No Google Cloud console, no API key, nothing to paste.

**Escape hatch (Advanced / `--byo`):** the existing BYO paste-wizard, demoted to an Advanced toggle. Required for Google Workspace-managed friends (whose org admin can block the shared app) and for anyone past the cap.

**Distribution:** Developer-ID-signed + **notarized + stapled DMG** via GitHub Releases, **Sparkle 2** auto-update (EdDSA appcast). Fully scriptable in GitHub Actions (`notarytool` + `stapler`).

**AI defaults:** local **Ollama** (zero cost/key) as default for summarize/draft; **OpenRouter-free** as a one-paste cloud upgrade; **BYO** Anthropic/OpenAI key for power users. Explicitly reject developer-proxied keys (~$5/active friend/mo, unbounded — violates free/no-middleman).

## Why this is the sweet spot (verified facts)

- **Zero middleman in DATA** — PKCE-protected, tokens per-friend in their own Keychain, **mail never transits any server**. There is no backend. This is the property that matters for "privacy #1."
- **One soft middleman in IDENTITY only** — the shared OAuth client is registered under the maintainer's Google account. Acceptable because data stays private.
- **Backend-less, free to friends, no CASA.** The only unavoidable money is **$99/yr Apple Developer** (maintainer-only — the user already pays this). On macOS 15/26 the right-click-open bypass is gone, so notarization is effectively mandatory for "just opens"; $99/yr buys trust, not middleman-ship (Apple gates whether the app opens, never whose Gmail it touches).

## Hard edges (honest)

- **~100 friends LIFETIME cap** on the shared unverified path — `gmail.modify` is a *restricted* scope, so the cap is non-resettable and one-way (counts everyone who ever consents, even after uninstall). Plenty for "friends," a permanent wall for "a product." BYO extends indefinitely past it.
- The **unverified interstitial is unavoidable** without paid CASA (~$540–$1,800/yr recurring, up to ~$4,500, + verified domain + privacy policy + annual re-assessment + a named legal owner = the real identity middleman). **Reject CASA** unless Hudson deliberately becomes a maintained public product past 100 users. That's the line between "friends" and "a company."
- **Workspace-managed friends** may be admin-blocked regardless → must use BYO. (Another reason BYO stays.)

## Foundation impact: ZERO engine change

Confirmed against the built code: `OAuthCredentials` is a plain 2-field struct constructed in one place (`AuthCommand.connect()`); nothing in GmailClient/SyncEngine/Store/AIKit branches on which client_id is used; LoopbackServer + PKCE are byte-identical for shared vs BYO; per-account Keychain is keyed by email, not client. **The shared-vs-BYO choice is a one-function credential-resolver decision, not rearchitecture.** M3–M7 build and ship unchanged against the existing BYO CLI wizard.

Onboarding-layer deltas (UI phase): a credentials resolver returning the bundled shared credentials by default + pasted values behind `--byo`; keep the interstitial copy + publish-to-production (a shared client MUST be Published or refresh tokens expire every 7 days); default AI to Ollama with the one-paste upgrades.

## Decide NOW (shapes near-term CI/onboarding)

1. **Commit to the hybrid in principle** — so the eventual onboarding is designed "default shared, Advanced BYO," not retrofitted. *(User's stated constraints already imply yes: privacy-preserving, free, Apple fee paid.)*
2. **Relax spec §6.1 wording** from "no Google credentials may ever appear in the repo" → "no Google credentials in the repo OR fixtures; the ONE shared Desktop `client_secret` is injected at CI build time from a secret store (never committed)." The shared `client_id` may be a compiled-in constant; the secret is CI-injected (Google treats the Desktop secret as non-confidential — PKCE is the real protection — but committing it trips both our secret-scan and Google's auto-disable scanners). **No action until the shared client is actually created (distribution phase); recorded so CI is structured right when it is.**
3. **Start Apple Developer Program enrollment early** — identity verification takes days–weeks. *(User already enrolled — done.)*

## User decisions (mostly pre-answered by the user's stated constraints)

- **Apple $99/yr** → YES (user already pays). ✓
- **Google/CASA** → never, stay $0/unverified-under-cap (matches free/no-middleman). ✓ (recommended)
- **Ethos (registered-app + interstitial)** → hybrid gives both; requires comfort that the maintainer's name is on the shared client. *Data stays private (user's #1), so recommended yes; confirm when we build onboarding.*
- **AI cost model** → Ollama default + OpenRouter-free upgrade + BYO (matches privacy/free). ✓ (recommended)
- **User-cap ceiling** → onboarding-copy detail; suggest routing to BYO at ~50–70 to keep headroom under the 100 wall. Decide when building onboarding.
- **Workspace friends in scope?** → if yes, they use BYO. Decide when building onboarding.
