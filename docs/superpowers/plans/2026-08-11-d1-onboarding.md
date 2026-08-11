# Hudson D1 — In-app onboarding + Sign in with Google (distribution app-side)

> Built by a Workflow: each task implement (TDD) → adversarial review → fix, sequentially in the `d1-onboarding` worktree.

**Goal:** A friend opens Hudson and gets online with **one "Sign in with Google" click** — no terminal, no OAuth console, no key pasting. Uses a bundled shared OAuth client by default (BYO as a fallback), reusing the loopback OAuth that already works.

**Architecture:** Port `HudsonCLI/AuthCommand.connect`'s proven loopback flow into an `@MainActor @Observable OnboardingModel` + a SwiftUI `OnboardingView`, behind a `SharedOAuth` credential resolver (compiled shared client by default; BYO override). `RootView` shows onboarding when no account is connected, the mailbox otherwise. Reuses `GmailKit` (`OAuthClient`, `LoopbackServer`, `KeychainTokenStore`) + `Store` (`upsertAccount`) unchanged.

**Tech Stack:** Swift 6, SwiftUI, GmailKit/Store. No new external deps. Design tokens ONLY (Palette/Typography/Metrics). House readability bar.

## Global Constraints
- **Privacy #1:** sign-in is loopback PKCE — tokens go straight to the user's Keychain, mail never touches a server. The shared client is an identity/branding seam only; it must NOT change the zero-data-middleman property. No telemetry.
- **No secret in the repo:** `SharedOAuth.clientID` is a compiled constant (safe to ship); `SharedOAuth.clientSecret` is **injected at build time** (env/Info.plist), never committed. Until the real values exist, `clientID` is an empty placeholder and the shared path cleanly falls back to BYO.
- Swift 6 strict concurrency; `@MainActor @Observable`. Two external deps only. Design tokens only.

## Interfaces to REUSE (read these — do not rebuild)
- `Sources/HudsonCLI/AuthCommand.swift` — `connect(clientID:clientSecret:)` is the exact flow to port: `LoopbackServer().start()` → `OAuthClient.authorizationURL(redirectURI:state:pkce:)` → open the URL in the browser → `server.waitForCallback(...)` → `oauth.exchangeCode(code, verifier:, redirectURI:)` → fetch profile (`GmailClient.profile`/`getProfile`) → `KeychainTokenStore.saveTokens`/`saveClientSecret` → `database.upsertAccount(email:clientID:consentedAt:)`.
- `Sources/GmailKit/OAuth/OAuthClient.swift` (`OAuthCredentials`, `authorizationURL`, `exchangeCode`), `Sources/GmailKit/OAuth/LoopbackServer.swift` (`start`/`waitForCallback`/`stop`), `Sources/GmailKit/OAuth/PKCE.swift`, `Sources/GmailKit/TokenStore/KeychainTokenStore.swift`.
- `Sources/HudsonUI/Model/AppModel.swift` (`account`, loads `primaryAccount`), `Sources/HudsonUI/Views/RootView.swift` (the launch `.task`).

---

## Task 1: SharedOAuth resolver
**Files:** `Sources/HudsonUI/Model/SharedOAuth.swift`; test `Tests/HudsonUITests/SharedOAuthTests.swift`.
**Produces:**
- `enum SharedOAuth { static let clientID: String; static func clientSecret() -> String?; static var isConfigured: Bool { !clientID.isEmpty } }` — `clientID` a compiled constant (EMPTY placeholder `""` for now, with a `// TODO(shared-client): real Desktop client id`); `clientSecret()` reads an injected value (env var `HUDSON_OAUTH_CLIENT_SECRET` at build, or an Info.plist key) — nil when absent.
- `static func credentials(byoClientID: String? = nil, byoSecret: String? = nil) -> OAuthCredentials?` — if BYO values are given, use them; else if `isConfigured` and a secret resolves, use the shared client; else `nil` (caller shows BYO entry).
**Steps:** test that with no shared config + no BYO → nil; with BYO → those creds; commit `feat(ui): SharedOAuth credential resolver (shared client + BYO fallback)`.

## Task 2: OnboardingModel (in-app Sign in with Google) — CRUX (opus)
**Files:** `Sources/HudsonUI/Model/OnboardingModel.swift`; test `Tests/HudsonUITests/OnboardingModelTests.swift`.
**Produces:** `@MainActor @Observable final class OnboardingModel` with:
- `enum Phase: Equatable { case welcome, chooseSignIn, signingIn, byoEntry, done, failed(String) }`; `private(set) var phase`.
- `let database: HudsonDatabase`; init injects a `tokenStore`/`transport`/`makeAuthClient` seam (so tests don't hit the real network/Keychain — mirror how ComposerModel/SummaryModel inject).
- `func signInWithGoogle() async` — ports `AuthCommand.connect` using `SharedOAuth.credentials()` (shared client). If `SharedOAuth.credentials()` is nil (not configured yet), route to `.byoEntry`. Runs: loopback start → authorizationURL → open browser (`NSWorkspace.shared.open(url)`; injectable for tests) → waitForCallback → exchangeCode → profile → save tokens/secret + `upsertAccount` → `.done`. On error → `.failed(message)`.
- `func signInBYO(clientID: String, clientSecret: String) async` — same flow with BYO creds.
- Reports `onConnected: (AccountRecord) -> Void` (host swaps onboarding → mailbox).
**Steps:** failing test with injected fakes: a scripted OAuth path (fake loopback returning a code, fake token exchange, fake profile) drives phase welcome→signingIn→done and calls `upsertAccount`; the not-configured-and-no-BYO path routes to `.byoEntry` and performs NO network. → implement (port AuthCommand.connect carefully) → commit `feat(ui): OnboardingModel — in-app Sign in with Google (loopback PKCE)`.

## Task 3: OnboardingView
**Files:** `Sources/HudsonUI/Views/OnboardingView.swift`; extend `RenderSmokeTests`.
**Design (Pencil onboarding `gy8VW`):** centered, `Palette.bgApp`. Welcome: "Hudson" wordmark (`Typography.serif(40, .semibold)`), tagline "The fastest email on the Mac. Owned by no one." (`Palette.inkSecondary`), three cards (`Palette.bgSurface`, `radiusLarge`) — **Free forever** (open source, MIT, BYO keys), **No server** (mail goes to Gmail from this Mac, nothing to a database), **Your keys** (all Gmail API keys are yours — or none) — and a `PrimaryButton` "Set up in about 5 minutes" → `chooseSignIn`.
- **chooseSignIn/signingIn:** a **"Sign in with Google"** `PrimaryButton`; ABOVE it a calm explainer card (`Palette.bgSurface`): *"Google will show a 'this app isn't verified' screen — that's expected for an independent app. Click **Advanced → Continue to Hudson** to proceed. Your mail never touches our servers."* A small "Use my own Google credentials" `QuietButton` → `byoEntry`. `signingIn` shows a spinner + "Waiting for Google…".
- **byoEntry:** two `Field`s (Client ID, Client Secret) + a "Connect" `PrimaryButton` + a one-line link-style note pointing at the console steps.
- **failed:** the error + a "Try again" button.
**Steps:** build bound to `OnboardingModel`; render-smoke hosts welcome + chooseSignIn + byoEntry; `swift test --filter RenderSmoke` green → commit `feat(ui): OnboardingView (welcome + Sign in with Google + BYO + unverified explainer)`.

## Task 4: Gate onboarding in the app
**Files:** modify `Sources/HudsonUI/Views/RootView.swift`, `Sources/HudsonUI/Model/AppModel.swift`.
**Produces:** on launch, if `AppModel.account == nil` (no connected account), `RootView` shows `OnboardingView`; on `onConnected`, it rebuilds the model for the new account and shows the mailbox (+ `startAutoSync()`). A returning user (account present) skips straight to the mailbox. `--demo` still bypasses onboarding (seeded account). Keep the existing loading placeholder while the model loads.
**Steps:** wire + a test that `AppModel` with no account signals the onboarding path (e.g. an `needsOnboarding` computed = `account == nil && !isDemo`); render-smoke of RootView-in-onboarding-state; → commit `feat(ui): gate first-launch onboarding (no account -> Sign in)`.

---

## Self-Review
- One-click friend sign-in via shared client + BYO fallback → T1/T2. Onboarding UI (welcome + unverified explainer) → T3. First-launch gate → T4. Reuses the working loopback OAuth; no engine changes. ✓
- Privacy: loopback PKCE, tokens to Keychain, no server; shared client is identity-only; no secret committed (build-injected). ✓
- Ships functional TODAY with BYO-in-app even before the real shared client id exists (empty placeholder → clean BYO fallback). ✓
