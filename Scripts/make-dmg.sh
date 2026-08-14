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
# Usage: ./Scripts/make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${HUDSON_VERSION:-0.1.0}"
APP="dist/Hudson.app"
DMG="dist/Hudson-${VERSION}.dmg"
VOLNAME="Hudson"

# 1. Build the .app (with the real icon baked in).
HUDSON_VERSION="$VERSION" ./Scripts/package-app.sh release

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

# Background art, rendered from the hudson.pen tokens. The 1x and 2x PNGs are
# folded into ONE HiDPI TIFF: Finder picks the right representation per display,
# which is what stops the art looking upscaled on a Retina Mac.
#
# Non-fatal, like the Finder styling below. Rendering needs a working Swift
# toolchain and AppKit; on a machine where that is unavailable the right outcome
# is a plainer installer, not a failed release build.
echo "Rendering installer background…"
BACKGROUND_TIFF="$STAGE/.background/background.tiff"
mkdir -p "$STAGE/.background"
if swift Scripts/make-dmg-background.swift Design/DMG >/dev/null 2>&1 \
  && tiffutil -cathidpicheck Design/DMG/background.png Design/DMG/background@2x.png \
       -out "$BACKGROUND_TIFF" >/dev/null 2>&1; then
  echo "  background rendered"
else
  echo "  WARN: could not render the background art; using a plain window." >&2
  rm -rf "$STAGE/.background"
fi

# Build a READ-WRITE image first. Finder can only record window geometry, icon
# positions and the background picture into a volume it can write to; the
# compressed read-only image users download is converted from it at the end.
#
# The existing $DMG is deliberately left alone until the new one is complete and
# only then moved into place. An earlier version deleted it up front, and when a
# later step failed the release artifact was simply gone.
RW_DMG="$(dirname "$STAGE")/rw.dmg"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov \
  -format UDRW -fs HFS+ "$RW_DMG" >/dev/null

MOUNT_POINT="/Volumes/$VOLNAME"

# If a volume named "Hudson" is already mounted — a copy of the release you
# happen to have open, say — macOS mounts this one as "Hudson 1" instead, while
# the AppleScript below addresses disk "$VOLNAME" by name. Left unchecked that
# styles somebody else's volume and reports success.
#
# Say so and stop, rather than force-ejecting it: this script runs on other
# people's machines, and silently unmounting a volume the user opened
# themselves is not its business.
if [[ -d "$MOUNT_POINT" ]]; then
  echo "ERROR: $MOUNT_POINT is already mounted." >&2
  echo "  Eject it and re-run — otherwise this build would mount as" >&2
  echo "  \"$VOLNAME 1\" and the window layout would be applied to the wrong volume." >&2
  exit 1
fi

hdiutil attach "$RW_DMG" -nobrowse -noautoopen >/dev/null

# Belt and braces: confirm we actually got the name we asked for before styling.
if [[ ! -d "$MOUNT_POINT" ]]; then
  echo "ERROR: image did not mount at $MOUNT_POINT; refusing to style blind." >&2
  exit 1
fi

# Icon coordinates below MUST match `appIconCenter` / `applicationsCenter` in
# make-dmg-background.swift, or the drawn arrow stops pointing at the folder.
#
# This is the one step that needs a real GUI session: it drives Finder, so it
# fails on a headless CI box and when Terminal lacks Automation permission for
# Finder. Treated as non-fatal on purpose — a plain-looking installer is a much
# better outcome than a failed release build.
echo "Laying out the installer window…"

# Only reference the background picture if the art actually rendered; naming a
# missing file makes Finder abort the whole layout, costing the icon placement
# too rather than just the artwork.
if [[ -f "$BACKGROUND_TIFF" ]]; then
  SET_BACKGROUND='set background picture of opts to file ".background:background.tiff"'
else
  SET_BACKGROUND=''
fi

if osascript <<APPLESCRIPT >/dev/null 2>&1
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 840, 520}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    $SET_BACKGROUND
    set position of item "Hudson.app" of container window to {170, 190}
    set position of item "Applications" of container window to {470, 190}
    close
    open
    update without registering applications
    delay 2
  end tell
end tell
APPLESCRIPT
then
  echo "  window styled"
else
  echo "  WARN: Finder styling skipped (needs a GUI session + Automation permission)." >&2
  echo "  The DMG is still valid, just with the default window." >&2
fi

# Let Finder's .DS_Store write land before the volume goes away.
sync
hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1

# Detaching returns before the kernel has finished releasing the device, so an
# immediate convert loses a race with it and fails "Resource temporarily
# unavailable". Retry briefly rather than failing the build.
STAGED_DMG="$(dirname "$STAGE")/staged.dmg"
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 \
      -o "$STAGED_DMG" -ov >/dev/null 2>&1; then
    break
  fi
  if [[ "$attempt" == 10 ]]; then
    echo "ERROR: hdiutil convert kept failing; $DMG left untouched." >&2
    exit 1
  fi
  sleep 2
done

mv -f "$STAGED_DMG" "$DMG"
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