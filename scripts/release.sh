#!/bin/zsh
# Builds a signed, notarized Carrot.dmg in dist/.
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
APP="build/DerivedData/Build/Products/Release/Carrot.app"
DIST="dist"
DMG="$DIST/Carrot-$VERSION.dmg"

notarize() {
  local result notary_status submission
  result=$(xcrun notarytool submit "$1" --apple-id "$APPLE_ID" --team-id "$TEAM_ID" \
    --password "$APP_SPECIFIC_PASSWORD" --wait --timeout 30m --output-format json)
  notary_status=$(print -r -- "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')
  submission=$(print -r -- "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')
  echo "    notarization $submission: $notary_status"
  if [[ "$notary_status" != "Accepted" ]]; then
    xcrun notarytool log "$submission" --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_SPECIFIC_PASSWORD"
    exit 1
  fi
}

echo "==> Building Carrot $VERSION"
xcodegen generate >/dev/null
xcodebuild -project Carrot.xcodeproj -scheme Carrot -configuration Release \
  -derivedDataPath build/DerivedData clean build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Authority=Developer ID|TeamIdentifier|flags=.*runtime"

echo "==> Notarizing the app"
rm -rf "$DIST" && mkdir -p "$DIST"
ditto -c -k --keepParent "$APP" "$DIST/Carrot.zip"
notarize "$DIST/Carrot.zip"
xcrun stapler staple "$APP"
rm "$DIST/Carrot.zip"

echo "==> Building the disk image"
create-dmg \
  --volname "Carrot" \
  --background "$ROOT/Resources/DMG/background.tiff" \
  --window-pos 200 160 --window-size 560 340 \
  --icon-size 112 --text-size 13 \
  --icon "Carrot.app" 150 160 \
  --app-drop-link 410 160 \
  --hide-extension "Carrot.app" \
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
  gh release create "v$VERSION" "$DMG" --title "Carrot $VERSION" --notes-file "$ROOT/docs/release-notes.md"
fi
