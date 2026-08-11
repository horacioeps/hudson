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
