#!/bin/bash
# Publishes a Tintkey release with Sparkle auto-update support. Run from the repo root with the signing and notary
# variables from scripts/build-app.sh set. Usage: VERSION=0.2.0 scripts/release.sh
#
# 1. builds, signs, notarizes and staples dist/Tintkey.dmg
# 2. signs the update with the Sparkle key in your keychain and writes docs/appcast.xml
# 3. prints the gh and git commands for the two public steps (it does NOT publish anything itself)
set -euo pipefail
cd "$(dirname "$0")/.."
: "${VERSION:?set VERSION, e.g. VERSION=0.2.0}"
REPO="akabdalla9124/tintkey"

./scripts/build-app.sh

STAGE="$(mktemp -d)"
cp dist/Tintkey.dmg "$STAGE/Tintkey-$VERSION.dmg"
# generate_appcast reads each archive's version, signs it with the keychain key and writes appcast.xml.
.build-app/artifacts/sparkle/Sparkle/bin/generate_appcast \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  "$STAGE"
cp "$STAGE/appcast.xml" docs/appcast.xml
cp "$STAGE/Tintkey-$VERSION.dmg" "dist/Tintkey-$VERSION.dmg"
rm -rf "$STAGE"

cat <<MSG

Ready:
  dist/Tintkey-$VERSION.dmg   (notarized, stapled)
  docs/appcast.xml            (signed update feed, served at https://tintkey.vercel.app/appcast.xml)

To publish (public steps, run them yourself or ask Claude):
  gh release create v$VERSION dist/Tintkey-$VERSION.dmg --title "Tintkey $VERSION" --notes "..."
  cp dist/Tintkey-$VERSION.dmg dist/Tintkey.dmg   # the site's latest/download link expects the name Tintkey.dmg
  gh release upload v$VERSION dist/Tintkey.dmg
  git add docs/appcast.xml && git commit -m "Appcast for $VERSION" && git push
MSG
