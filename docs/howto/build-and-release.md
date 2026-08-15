# How to build and release Hudson

From a source checkout to a signed, Apple-notarized DMG that installs with no
Gatekeeper warning.

There are three levels here. Pick the one you need — you do not need an Apple
Developer account to build and run Hudson, only to hand it to someone else.

| Level | Command | Needs |
|---|---|---|
| Dev build | `swift build` | nothing |
| Local `.app` | `./Scripts/package-app.sh` | nothing |
| Release DMG | `./Scripts/make-dmg.sh` | Developer ID + notary credentials |

## Prerequisites

- macOS 15+, Xcode 16+, Apple silicon (there is no Intel build)
- For a release: an Apple Developer account with a **Developer ID Application**
  certificate in the login Keychain, and a stored `notarytool` profile
- A GUI session for the DMG's Finder styling step (it is optional — see below)

## Level 1: build and run from source

```bash
git clone https://github.com/hudson-mail/hudson && cd hudson
swift build
swift test                    # the gate — everything green before you ship

swift run HudsonApp --demo    # the app, synthetic mailbox
./Scripts/sign-cli.sh         # stable identity so the Keychain trusts rebuilds
.build/debug/hudson --help
```

`sign-cli.sh` signs the CLI with a stable `hudson-dev` identity. Without it,
every `swift build` produces a different ad-hoc identity and the Keychain
re-prompts on each run. If you do not have that identity yet the script falls
back to ad-hoc signing and prints the one-time setup:

> Keychain Access → Certificate Assistant → Create a Certificate…
> Name: `hudson-dev` · Identity type: Self-Signed Root · Certificate type: Code Signing

Override with `HUDSON_SIGN_IDENTITY`, or pass a different binary path as `$1`.

## Level 2: a double-clickable .app

```bash
./Scripts/package-app.sh release        # or: ./Scripts/package-app.sh debug
open dist/Hudson.app
```

This builds `HudsonApp`, assembles `dist/Hudson.app`, and:

- Copies SwiftPM resource bundles (bundled fonts) into `Contents/Resources`.
  **Not `Contents/MacOS`** — an unsigned app launches fine either way, but
  `codesign` rejects the whole bundle as "bundle format unrecognized" if they
  are in `MacOS`, so notarization would fail later.
- Builds a full `.icns` (16→1024, @1x/@2x) from `Design/AppIcon/Hudson-1024.png`.
- Writes `Info.plist` with bundle id `app.hudson.mac` and
  `LSMinimumSystemVersion 15.0`.

Set the version with `HUDSON_VERSION` (defaults to `0.1.0`):

```bash
HUDSON_VERSION=0.2.0 ./Scripts/package-app.sh release
```

### The shared OAuth secret

If `HUDSON_OAUTH_CLIENT_SECRET` is exported, the script injects it into the
bundle's `Info.plist` via `PlistBuddy`, so it never appears in the script or
its logs. `SharedOAuth.clientSecret()` reads that key — this is what makes
onboarding's one-click "Sign in with Google" work.

Without it the app falls back to BYO sign-in, where the user supplies their own
Google Cloud credentials. **That is a fully supported path**, not a degraded
one, so a build without the secret is a legitimate build.

The secret is never committed. It lives in git-ignored
`Scripts/hudson-secrets.env`.

## Level 3: the signed, notarized DMG

```bash
source Scripts/hudson-secrets.env      # DEVELOPER_ID, NOTARY_PROFILE, HUDSON_OAUTH_CLIENT_SECRET
./Scripts/make-dmg.sh
```

Output: `dist/Hudson-<version>.dmg`, signed, notarized, and stapled.

### Credentials

```bash
export DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
export NOTARY_PROFILE="hudson-notary"
```

Create the notary profile once:

```bash
xcrun notarytool store-credentials "hudson-notary" \
  --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
```

The app-specific password comes from appleid.apple.com. Raw credentials work
too, via `APPLE_ID` + `APPLE_TEAM_ID` + `APPLE_APP_PASSWORD`.

Every variable is optional and the script degrades sensibly: no `DEVELOPER_ID`
gives an unsigned DMG (fine for your own machine, right-click → Open
elsewhere); signing without notary credentials gives a signed but un-notarized
DMG.

### What the script does

1. Builds the `.app` via `package-app.sh`.
2. Signs inner binaries first, then the app with `--options runtime` (the
   hardened runtime notarization requires). Hudson needs no entitlements — no
   sandbox; Keychain and loopback both work under the hardened runtime.
3. Stages a drag-to-`/Applications` layout and renders the installer
   background, folding the 1x and 2x PNGs into one HiDPI TIFF so Finder picks
   the right representation per display.
4. Creates a **read-write** image, mounts it, and drives Finder via AppleScript
   to set window geometry, icon positions, and the background. Read-write
   because Finder can only record that into a volume it can write to.
5. Converts to a compressed read-only `UDZO` image.
6. Signs the DMG, submits to the Apple notary service with `--wait`, and
   staples the ticket.

### Deliberate robustness

Worth knowing, because these are the parts that will confuse you if you hit
them:

- **The existing DMG is left alone until the new one is complete**, then moved
  into place. An earlier version deleted it up front, and a later failure meant
  the release artifact was simply gone.
- **The script refuses to run if `/Volumes/Hudson` is already mounted.** macOS
  would mount the new image as "Hudson 1" while the AppleScript addresses
  `disk "Hudson"` by name — styling someone else's volume and reporting
  success. It says so and stops rather than force-ejecting a volume you opened.
- **`hdiutil convert` is retried up to 10 times.** Detaching returns before the
  kernel has released the device, so an immediate convert loses the race with
  "Resource temporarily unavailable".
- **Background rendering and Finder styling are non-fatal.** Both need a GUI
  session (and Automation permission for Finder); on a headless box the right
  outcome is a plainer installer, not a failed release build.
- **Icon coordinates in the AppleScript must match** `appIconCenter` /
  `applicationsCenter` in `Scripts/make-dmg-background.swift`, or the drawn
  arrow stops pointing at the folder. Change both together.

## Verification

```bash
# the app is signed with the hardened runtime
codesign --verify --deep --strict --verbose=2 dist/Hudson.app

# the notarization ticket is stapled
xcrun stapler validate dist/Hudson-0.1.0.dmg

# Gatekeeper accepts it
spctl -a -t open --context context:primary-signature -v dist/Hudson-0.1.0.dmg
```

Then the real test: copy the DMG to another Mac, double-click, drag to
Applications, launch. No Gatekeeper warning is the pass condition.

On first launch Google shows an unverified-app screen. That is expected and
unrelated to notarization — removing it requires an annual paid third-party
security audit. Advanced → Continue to Hudson.

## Quick rebuild without notarizing

Notarization takes minutes. For a local loop:

```bash
source Scripts/hudson-secrets.env
./Scripts/package-app.sh release
codesign --force --deep --options runtime --timestamp \
  --sign "$DEVELOPER_ID" dist/Hudson.app
```

Signed but not notarized — fine on your own machine, needs right-click → Open
on anyone else's.

## CI

`.github/workflows/ci.yml` runs on `macos-15`: a **secret scan**, then
`swift test`.

The secret scan fails the build on an OAuth client secret (`GOCSPX-…`), a
private key block, an OAuth token (`ya29.…`), or any `googleusercontent.com`
client id **other than** the known shared Desktop client id, which is public
and intentionally committed (Google does not treat a Desktop-app client id as
confidential).

CI does not build releases. Signing and notarization need credentials that
should not live in CI for a project this size.

## Troubleshooting

**`bundle format unrecognized`** — resource bundles ended up in
`Contents/MacOS`. `package-app.sh` puts them in `Contents/Resources`; if you
changed that, change it back.

**Notarization rejected** — run
`xcrun notarytool log <submission-id> --keychain-profile hudson-notary`. Almost
always a missing hardened runtime or an unsigned nested binary.

**`ERROR: /Volumes/Hudson is already mounted`** — eject the mounted Hudson
volume and re-run. Working as designed.

**`hdiutil convert` fails after 10 retries** — something else is holding the
device. Check for a stray mount with `hdiutil info`.

**Finder styling skipped** — you are headless, or Terminal lacks Automation
permission for Finder (System Settings → Privacy & Security → Automation).
The DMG is still valid, just with a default window.

**App uses BYO sign-in when you expected one-click** —
`HUDSON_OAUTH_CLIENT_SECRET` was not exported. `source Scripts/hudson-secrets.env`
first.

## See also

- [HudsonUI reference](../reference/hudson-ui.md#bootstraps) — `SharedOAuth`
- [GmailKit reference](../reference/gmailkit.md#auth) — the OAuth flow
- [STATUS.md](../../STATUS.md) — current distribution state and credentials
