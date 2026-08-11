#!/usr/bin/env bash
# Builds a distributable Hudson.dmg (drag-to-Applications layout).
#
# Works TODAY unsigned (fine for your own machine + right-click→Open on a
# friend's Mac). The moment you export a "Developer ID Application" cert and
# set the env vars below, the SAME script code-signs (hardened runtime) and
# notarizes + staples, so friends get a clean double-click install with no
# Gatekeeper warning.
#
#   Signing (optional):
#     DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
#   Notarization (optional, needs signing too) — either a saved notarytool
#   profile:
#     NOTARY_PROFILE="hudson-notary"     # from: xcrun notarytool store-credentials
#   or raw credentials:
#     APPLE_ID="you@example.com"
#     APPLE_TEAM_ID="TEAMID"
#     APPLE_APP_PASSWORD="abcd-efgh-ijkl-mnop"   # appleid.apple.com app-specific password
#
# Usage: ./scripts/make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${HUDSON_VERSION:-0.1.0}"
APP="dist/Hudson.app"
DMG="dist/Hudson-${VERSION}.dmg"
VOLNAME="Hudson"

# 1. Build the .app (with the real icon baked in).
HUDSON_VERSION="$VERSION" ./scripts/package-app.sh release

# 2. Code-sign (only if a Developer ID is provided).
if [[ -n "${DEVELOPER_ID:-}" ]]; then
  echo "Signing $APP as: $DEVELOPER_ID"
  # Sign inner bundles/frameworks first (deep), then the app, with the
  # hardened runtime that notarization requires. Hudson needs no special
  # entitlements (no sandbox; Keychain + loopback work under hardened runtime).
  find "$APP/Contents/MacOS" -type f -perm +111 -print0 2>/dev/null \
    | xargs -0 -I{} codesign --force --options runtime --timestamp \
        --sign "$DEVELOPER_ID" {} || true
  codesign --force --deep --options runtime --timestamp \
    --sign "$DEVELOPER_ID" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
  echo "Signed OK"
else
  echo "No DEVELOPER_ID set — building an UNSIGNED app (right-click→Open on other Macs)."
fi

# 3. Assemble a drag-to-install DMG staging folder.
STAGE="$(mktemp -d)/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # the classic "drag me →" target

rm -f "$DMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$(dirname "$STAGE")"
echo "Built $DMG"

# 4. Sign the DMG itself + notarize + staple (only with full creds).
if [[ -n "${DEVELOPER_ID:-}" ]]; then
  codesign --force --sign "$DEVELOPER_ID" "$DMG"
fi

NOTARIZE=0
NOTARY_ARGS=()
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  NOTARIZE=1; NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]]; then
  NOTARIZE=1
  NOTARY_ARGS=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")
fi

if [[ "$NOTARIZE" == 1 ]]; then
  if [[ -z "${DEVELOPER_ID:-}" ]]; then
    echo "Notarization needs a signed app — set DEVELOPER_ID too. Skipping." >&2
  else
    echo "Submitting to Apple notary service (this can take a few minutes)…"
    xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait
    echo "Stapling notarization ticket…"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    echo "Notarized + stapled OK"
  fi
else
  echo "No notary credentials — skipping notarization (fine for local testing)."
fi

echo ""
echo "→ $DMG"
ls -lh "$DMG" | awk '{print "  size: "$5}'