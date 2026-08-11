#!/usr/bin/env bash
# Packages HudsonApp into a double-clickable Hudson.app bundle (UNSIGNED for
# local dev; the notarized DMG step is added once the Apple cert is wired).
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"

echo "Building HudsonApp ($CONFIG)…"
swift build -c "$CONFIG" --product HudsonApp

BIN=".build/$CONFIG/HudsonApp"
APP="dist/Hudson.app"
VERSION="${HUDSON_VERSION:-0.1.0}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/HudsonApp"

# SwiftPM resource bundles (bundled fonts, etc.) go in Contents/Resources —
# that's the FIRST location `Bundle.module` probes (via Bundle.main.resourceURL)
# AND the only spot codesign accepts a nested bundle. Putting them in
# Contents/MacOS launches fine unsigned but makes codesign reject the whole
# app as "bundle format unrecognized," so it must be Resources for notarization.
shopt -s nullglob
for b in ".build/$CONFIG"/*.bundle; do cp -R "$b" "$APP/Contents/Resources/"; done

# App icon: build a full .icns (16→1024, @1x/@2x) from the committed 1024
# master exported from the Pencil design, so the Dock/Finder show the real
# deep-green Hudson mark instead of the generic executable placeholder.
ICON_MASTER="Design/AppIcon/Hudson-1024.png"
if [[ -f "$ICON_MASTER" ]]; then
  ICONSET="$(mktemp -d)/Hudson.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size"           "$ICON_MASTER" --out "$ICONSET/icon_${size}x${size}.png"     >/dev/null
    sips -z $((size*2)) $((size*2))   "$ICON_MASTER" --out "$ICONSET/icon_${size}x${size}@2x.png"  >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Hudson.icns"
  rm -rf "$(dirname "$ICONSET")"
  echo "Baked app icon → Resources/Hudson.icns"
else
  echo "WARN: $ICON_MASTER missing — packaging without a custom icon" >&2
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Hudson</string>
  <key>CFBundleDisplayName</key><string>Hudson</string>
  <key>CFBundleIdentifier</key><string>app.hudson.mac</string>
  <key>CFBundleExecutable</key><string>HudsonApp</string>
  <key>CFBundleIconFile</key><string>Hudson</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
</dict></plist>
PLIST

echo "Built $APP (v$VERSION, unsigned)"
