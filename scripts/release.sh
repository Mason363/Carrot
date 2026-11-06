#!/bin/zsh
# Builds a signed, notarized Foreword.dmg in dist/.
#
#   APPLE_ID=you@example.com APP_SPECIFIC_PASSWORD=xxxx-xxxx-xxxx-xxxx scripts/release.sh [--publish]
#
# Requires a "Developer ID Application" certificate in the keychain, xcodegen and create-dmg.
# With --publish, uploads the DMG to a GitHub release for the current version (needs gh).
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

TEAM_ID="${TEAM_ID:-8GFSXN32MA}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
: "${APPLE_ID:?Set APPLE_ID to the Apple ID used for notarization}"
: "${APP_SPECIFIC_PASSWORD:?Set APP_SPECIFIC_PASSWORD to an app-specific password for APPLE_ID}"

VERSION=$(grep -m1 'MARKETING_VERSION' project.yml | sed -E 's/.*"([^"]+)".*/\1/')
APP="build/DerivedData/Build/Products/Release/Foreword.app"
DIST="dist"
DMG="$DIST/Foreword-$VERSION.dmg"

notarize() {
  xcrun notarytool submit "$1" --apple-id "$APPLE_ID" --team-id "$TEAM_ID" \
    --password "$APP_SPECIFIC_PASSWORD" --wait --timeout 30m
}

echo "==> Building Foreword $VERSION"
xcodegen generate >/dev/null
xcodebuild -project Foreword.xcodeproj -scheme Foreword -configuration Release \
  -derivedDataPath build/DerivedData clean build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Authority=Developer ID|TeamIdentifier|flags=.*runtime"

echo "==> Notarizing the app"
rm -rf "$DIST" && mkdir -p "$DIST"
ditto -c -k --keepParent "$APP" "$DIST/Foreword.zip"
notarize "$DIST/Foreword.zip"
xcrun stapler staple "$APP"
rm "$DIST/Foreword.zip"

echo "==> Building the disk image"
create-dmg \
  --volname "Foreword" \
  --window-pos 200 160 --window-size 560 340 \
  --icon-size 112 --text-size 13 \
  --icon "Foreword.app" 150 160 \
  --app-drop-link 410 160 \
  --hide-extension "Foreword.app" \
  --no-internet-enable \
  "$DMG" "$APP" >/dev/null
codesign --sign "$IDENTITY" --timestamp "$DMG"

echo "==> Notarizing the disk image"
notarize "$DMG"
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

shasum -a 256 "$DMG"
echo "==> Done: $DMG"

if [[ "${1:-}" == "--publish" ]]; then
  echo "==> Publishing GitHub release v$VERSION"
  gh release create "v$VERSION" "$DMG" --title "Foreword $VERSION" --notes-file "$ROOT/docs/release-notes.md"
fi
