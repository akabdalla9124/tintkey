#!/bin/bash
# Builds dist/Tintkey.app and dist/Tintkey.dmg. Ad-hoc signed unless SIGN_ID is set
# (e.g. SIGN_ID="Developer ID Application: Name (TEAMID)"). With NOTARY_PROFILE set (a profile saved by
# `xcrun notarytool store-credentials`), or NOTARY_KEY/NOTARY_KEY_ID/NOTARY_ISSUER (App Store Connect API key),
# the .dmg is also notarized and stapled for downloads outside the App Store.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
SCRATCH=".build-app"
swift build -c release --scratch-path "$SCRATCH" --product Tintkey
BIN="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)/Tintkey"

APP="dist/Tintkey.app"
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Tintkey"
# App icon: drop a square 1024x1024 PNG at assets/icon-1024.png and it is converted to AppIcon.icns.
ICON_KEY=""
if [ -f assets/icon-1024.png ]; then
  SET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$SET"
  for s in 16 32 128 256 512; do
    sips -z $s $s assets/icon-1024.png --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) assets/icon-1024.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o "$APP/Contents/Resources/AppIcon.icns"
  ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
fi

# Menu bar template icon (black on transparent; macOS tints it for light/dark menu bars).
for f in assets/MenuBarIcon.png assets/MenuBarIcon@2x.png; do [ -f "$f" ] && cp "$f" "$APP/Contents/Resources/"; done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Tintkey</string>
  <key>CFBundleDisplayName</key><string>Tintkey</string>
  <key>CFBundleIdentifier</key><string>dev.tintkey.app</string>
  <key>CFBundleExecutable</key><string>Tintkey</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  ${ICON_KEY}
  <key>LSUIElement</key><true/>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>dev.tintkey.app</string>
    <key>CFBundleURLSchemes</key><array><string>tintkey</string></array>
  </dict></array>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

if [ -n "${SIGN_ID:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
else
  codesign --force --options runtime --sign - "$APP"
fi

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Tintkey" -srcfolder "$STAGE" -ov -format UDZO "dist/Tintkey.dmg" >/dev/null
rm -rf "$STAGE"

if [ -n "${SIGN_ID:-}" ]; then codesign --force --timestamp --sign "$SIGN_ID" dist/Tintkey.dmg; fi
if [ -n "${NOTARY_PROFILE:-}" ]; then
  AUTH=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${NOTARY_KEY:-}" ]; then
  # No saved profile: authenticate directly with the App Store Connect API key (.p8).
  AUTH=(--key "$NOTARY_KEY" --key-id "${NOTARY_KEY_ID:?set NOTARY_KEY_ID}" --issuer "${NOTARY_ISSUER:?set NOTARY_ISSUER}")
fi
if [ -n "${AUTH+x}" ]; then
  xcrun notarytool submit dist/Tintkey.dmg "${AUTH[@]}" --wait
  xcrun stapler staple dist/Tintkey.dmg
fi
echo "Built dist/Tintkey.app and dist/Tintkey.dmg"
