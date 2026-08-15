import GmailKit
import Store
import SwiftUI

/// The first-launch flow: a welcome pitch, then one click of "Sign in with
/// Google" (the bundled shared OAuth client), falling back to BYO credential
/// entry whenever the shared client isn't configured (or the user prefers
/// their own). Mirrors the Pencil onboarding frame (`gy8VW`) and binds
/// directly to `OnboardingModel` (Task 2) — this view makes no Store/GmailKit
/// calls of its own, matching every other Hudson view's "presentational
/// only" contract (`ComposerView`, `ThreadView`, `SearchView`, ...): every
/// action here is exactly one `OnboardingModel` method call, and the phase
/// transition that follows is what actually re-renders the screen.
///
/// **Privacy #1 — said out loud, not just true.** Two spots on screen make
/// the zero-data-middleman property legible to a first-time user, not just
/// true in the code underneath: the welcome screen's "No server" card, and
/// the sign-in screen's explainer ("Your mail never touches our servers").
public struct OnboardingView: View {
    private let model: OnboardingModel

    /// Local, view-only draft state for the BYO credential fields. Unlike
    /// `ComposerModel`'s bound `to`/`subject`/etc., `OnboardingModel` has
    /// nowhere to hold in-progress text — it only ever receives the FINAL
    /// `clientID`/`clientSecret` pair, as arguments to `signInBYO` — so these
    /// two fields live here, the same way `ComposerView`'s `isCcVisible`/
    /// `placeholderToastText` are view-local rather than model state.
    @State private var byoClientID = ""
    @State private var byoClientSecret = ""
    /// The AI-key step's field. Never persisted from here directly — it is
    /// handed to `SettingsModel`, which owns the Keychain write.
    @State private var aiKey = ""
    /// Consent to egress, deliberately defaulting to OFF and deliberately
    /// separate from having entered a key. See `aiKeyScreen`.
    @State private var aiOptIn = false
    /// A refusal or failure from `SettingsModel.save(optIn:)`, surfaced on the
    /// step instead of being discarded — the whole point of `save` reporting
    /// what it actually wrote.
    @State private var aiBanner: String?

    private var trimmedAIKey: String {
        aiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Writes the AI configuration, then leaves the step — but only writes at
    /// all when the user actually supplied something.
    ///
    /// The empty-field guard is not a micro-optimization. `SettingsModel.save`
    /// unconditionally rewrites all four `ai_config` rows with `provider =
    /// .anthropic` and a nil base URL, so calling it for a user who typed
    /// nothing would overwrite a RETURNING address's stored provider — turning
    /// a local, nothing-leaves-the-machine model into cloud Anthropic. That is
    /// exactly the downgrade `revokeAIOptIn` was introduced to prevent, so
    /// this screen must not reintroduce it from the other side.
    private func saveAIKeyAndContinue() async {
        aiBanner = nil
        // Nothing typed and no consent given: this is a Skip in all but name.
        guard !trimmedAIKey.isEmpty || aiOptIn else {
            model.finishAIKeyStep()
            return
        }
        // No account means nothing to scope the config to; fall through rather
        // than writing a row under an empty address.
        guard let email = model.connectedRecord?.email else {
            model.finishAIKeyStep()
            return
        }
        let settings = SettingsModel(database: model.database, account: email)
        // Load first, so an address that already has a configuration keeps it
        // rather than having Anthropic assumed onto it.
        await settings.load()
        settings.provider = .anthropic
        settings.apiKey = aiKey
        await settings.save(optIn: aiOptIn)
        // A refusal means the user asked for something that did not happen —
        // stay on the step and say so, rather than silently continuing.
        if aiOptIn && !settings.isEnabled {
            aiBanner = settings.banner
            return
        }
        model.finishAIKeyStep()
    }

    public init(model: OnboardingModel) {
        self.model = model
    }

    public var body: some View {
        ZStack {
            Palette.bgApp.ignoresSafeArea()
            content
                .frame(maxWidth: 460)
                .padding(.horizontal, Metrics.unit * 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Renders purely off `model.phase` — no view-local phase tracking, so
    /// this can never drift from what `OnboardingModel` actually thinks is
    /// happening.
    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .welcome:
            welcomeScreen
        case .chooseSignIn:
            signInScreen(isSigningIn: false)
        case .signingIn:
            signInScreen(isSigningIn: true)
        case .aiKey:
            aiKeyScreen
        case .byoEntry:
            byoEntryScreen
        case .done:
            // The host (Task 4's `RootView`) swaps this view out entirely on
            // `onConnected`, so `.done` is only ever on screen for the
            // instant between that landing and the swap — a quiet no-op
            // here beats flashing a "success" screen nobody asked to see.
            EmptyView()
        case .failed(let message):
            failedScreen(message: message)
        }
    }

    // MARK: - Welcome

    private var welcomeScreen: some View {
        VStack(spacing: Metrics.unit * 8) {
            VStack(spacing: Metrics.unit * 3) {
                Text("Hudson")
                    .font(Typography.serif(40, .semibold))
                    .foregroundStyle(Palette.ink)
                Text("The fastest email on the Mac. Owned by no one.")
                    .font(Typography.ui(15))
                    .foregroundStyle(Palette.inkSecondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: Metrics.unit * 3) {
                featureCard(
                    icon: "infinity",
                    title: "Free forever",
                    body: "Open source, MIT-licensed. Bring your own keys if you'd like.")
                featureCard(
                    icon: "lock.shield",
                    title: "No server",
                    body:
                        "Mail goes straight from this Mac to Gmail — nothing passes through a database of ours."
                )
                featureCard(
                    icon: "key.fill",
                    title: "Your keys",
                    body: "Every Gmail API key involved is yours — or none at all.")
            }

            PrimaryButton(title: "Set up in about 5 minutes", action: model.beginSetup)
        }
    }

    /// One pitch card on the welcome screen — an icon, a bold title, and a
    /// one-line explanation, laid out left-to-right on `bgSurface` so the
    /// three cards read as a short, scannable list rather than a wall of
    /// text.
    private func featureCard(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: Metrics.unit * 3) {
            Image(systemName: icon)
                .font(Typography.ui(16))
                .foregroundStyle(Palette.accent)
                .frame(width: Metrics.unit * 6)
            VStack(alignment: .leading, spacing: Metrics.unit) {
                Text(title)
                    .font(Typography.ui(13, .semibold))
                    .foregroundStyle(Palette.ink)
                Text(body)
                    .font(Typography.ui(12))
                    .foregroundStyle(Palette.inkSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(Metrics.unit * 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusLarge))
    }

    // MARK: - Sign in with Google (chooseSignIn / signingIn)

    /// `chooseSignIn` and `signingIn` share one layout — the title and the
    /// unverified-app explainer never move — only the button area swaps
    /// between the "Sign in with Google" affordance and a spinner, so a
    /// sign-in in flight never looks like a different screen.
    private func signInScreen(isSigningIn: Bool) -> some View {
        VStack(spacing: Metrics.unit * 6) {
            Text("Sign in with Google")
                .font(Typography.serif(28, .semibold))
                .foregroundStyle(Palette.ink)

            explainerCard

            if isSigningIn {
                VStack(spacing: Metrics.unit * 3) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for Google…")
                        .font(Typography.ui(13))
                        .foregroundStyle(Palette.inkSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Metrics.unit * 2)
            } else {
                PrimaryButton(
                    title: "Sign in with Google",
                    action: { Task { await model.signInWithGoogle() } })
                QuietButton(title: "Use my own Google credentials", action: model.showBYOEntry)
            }
        }
    }

    /// The calm, expected-not-alarming explanation of Google's "unverified
    /// app" interstitial — every small/independent OAuth client sees it
    /// (Hudson has no Google-run security review, by design: that review
    /// would hand Google an audit trail Hudson otherwise keeps off any
    /// server). Framing this BEFORE the browser opens, not after a confused
    /// bail-out on Google's own page, is the entire point of this card.
    private var explainerCard: some View {
        Text(
            "Google will show a \"this app isn't verified\" screen — that's expected for an independent app. Click **Advanced → Continue to Hudson** to proceed. Your mail never touches our servers."
        )
        .font(Typography.ui(13))
        .foregroundStyle(Palette.inkSecondary)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(Metrics.unit * 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusLarge))
    }

    // MARK: - BYO credential entry

    /// The optional AI-key step, shown once the account is connected and its
    /// mail is ALREADY downloading behind this screen (see
    /// `OnboardingModel.onAccountPersisted`).
    ///
    /// Three things this copy has to get right, all of them consent
    /// questions rather than layout ones:
    ///
    /// - **Skip is a peer of Save, not a footnote.** Hudson is a complete mail
    ///   client with no AI configured. A step that reads as required would be
    ///   a lie, and would sour the one-click promise for someone who never
    ///   wants AI.
    /// - **It names what would leave the machine, and when.** "only when you
    ///   ask" is the literal enforcement (`Invocation` + `EgressGuard`), not
    ///   marketing.
    /// - **Saving a key does not switch AI on.** `save(optIn: false)` stores
    ///   the key and leaves every feature opted out, because pasting a key and
    ///   agreeing to send your email to a provider are two different
    ///   decisions. The toggle below is the second one, and it defaults off.
    private var aiKeyScreen: some View {
        VStack(alignment: .leading, spacing: Metrics.unit * 5) {
            VStack(alignment: .leading, spacing: Metrics.unit * 2) {
                Text("Add an AI key")
                    .font(Typography.serif(24, .semibold))
                    .foregroundStyle(Palette.ink)
                Text("Optional. Your mail is already downloading in the background.")
                    .font(Typography.ui(13))
                    .foregroundStyle(Palette.inkSecondary)
            }

            labeledField(
                "Anthropic API key", placeholder: "sk-ant-…", text: $aiKey, isSecure: true)

            Toggle(isOn: $aiOptIn) {
                Text("Let Hudson send mail to Anthropic when I ask it to")
                    .font(Typography.ui(12))
                    .foregroundStyle(Palette.inkSecondary)
            }
            .toggleStyle(.switch)
            .tint(Palette.accent)
            // Consent is meaningless without a key to consent against, and
            // `save(optIn:)` would refuse it anyway — disabling here makes the
            // refusal unreachable instead of surfacing it as an error after
            // the fact.
            .disabled(trimmedAIKey.isEmpty)
            .onChange(of: trimmedAIKey.isEmpty) { _, isEmpty in
                if isEmpty { aiOptIn = false }
            }

            HStack(spacing: Metrics.unit * 3) {
                PrimaryButton(
                    title: "Save and continue",
                    action: { Task { await saveAIKeyAndContinue() } })
                QuietButton(title: "Skip", action: { model.finishAIKeyStep() })
            }

            if let aiBanner {
                Text(aiBanner)
                    .font(Typography.ui(11))
                    .foregroundStyle(Palette.danger)
            }

            // Names BOTH things the toggle grants. An earlier draft said "only
            // the thread or question you explicitly act on leaves your Mac",
            // which was not true: this single consent also covers
            // `.voiceProfile`, and `VoiceProfile.generate` reads a sample of
            // SENT mail — messages unrelated to whatever thread you acted on —
            // to learn how you write. Consent copy that understates the grant
            // is worse than no copy.
            Text(
                "Nothing is ever sent on its own — no summarizing in the background, no scanning. Only what you explicitly act on leaves your Mac: the thread you summarize, the question you ask, and — when you ask for a draft in your own voice — a sample of your sent mail, so it can learn how you write. Only to the provider whose key you entered. You can change or remove this any time in Settings."
            )
            .font(Typography.ui(11))
            .foregroundStyle(Palette.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var byoEntryScreen: some View {
        VStack(alignment: .leading, spacing: Metrics.unit * 5) {
            VStack(alignment: .leading, spacing: Metrics.unit * 2) {
                Text("Use your own Google credentials")
                    .font(Typography.serif(24, .semibold))
                    .foregroundStyle(Palette.ink)
                Text(
                    "Create a free OAuth client in the Google Cloud console, then paste its Client ID and Client Secret below."
                )
                .font(Typography.ui(13))
                .foregroundStyle(Palette.inkSecondary)
            }

            labeledField(
                "Client ID", placeholder: "xxxxx.apps.googleusercontent.com", text: $byoClientID)
            labeledField(
                "Client Secret", placeholder: "GOCSPX-…", text: $byoClientSecret, isSecure: true)

            PrimaryButton(
                title: "Connect",
                action: {
                    Task {
                        await model.signInBYO(
                            clientID: byoClientID, clientSecret: byoClientSecret)
                    }
                })

            Text(
                "Need steps? console.cloud.google.com → APIs & Services → Credentials → OAuth client ID (Desktop app)."
            )
            .font(Typography.ui(11))
            .foregroundStyle(Palette.inkTertiary)
        }
    }

    /// A labeled text field for the BYO form — a small caption above a
    /// bordered, `bgSunken` field, matching this screen's own card-on-
    /// `bgApp` layering rather than `ComposerView`'s inline label convention
    /// (that one fits a single-line compose header; this is a short form).
    /// `isSecure` swaps in a `SecureField` for the Client Secret, so it never
    /// echoes to the screen.
    @ViewBuilder
    private func labeledField(
        _ label: String, placeholder: String, text: Binding<String>, isSecure: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: Metrics.unit) {
            Text(label)
                .font(Typography.ui(12, .medium))
                .foregroundStyle(Palette.inkTertiary)
            Group {
                if isSecure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .textFieldStyle(.plain)
            .font(Typography.ui(13))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, Metrics.unit * 3)
            .padding(.vertical, Metrics.unit * 2)
            .background(Palette.bgSunken)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusMedium))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radiusMedium)
                    .strokeBorder(Palette.border, lineWidth: 1)
            )
        }
    }

    // MARK: - Failed

    private func failedScreen(message: String) -> some View {
        VStack(spacing: Metrics.unit * 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(Typography.ui(28))
                .foregroundStyle(Palette.danger)
            Text(message)
                .font(Typography.ui(14))
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
            PrimaryButton(title: "Try again", action: model.retry)
        }
    }
}

#Preview("Welcome") {
    let db = try! HudsonDatabase.inMemory()
    let model = OnboardingModel(database: db, tokenStore: InMemoryTokenStore())
    return OnboardingView(model: model)
        .frame(width: 900, height: 700)
}

#Preview("Sign in with Google") {
    let db = try! HudsonDatabase.inMemory()
    let model = OnboardingModel(database: db, tokenStore: InMemoryTokenStore())
    model.beginSetup()
    return OnboardingView(model: model)
        .frame(width: 900, height: 700)
}

#Preview("Use your own credentials") {
    let db = try! HudsonDatabase.inMemory()
    let model = OnboardingModel(database: db, tokenStore: InMemoryTokenStore())
    model.showBYOEntry()
    return OnboardingView(model: model)
        .frame(width: 900, height: 700)
}
