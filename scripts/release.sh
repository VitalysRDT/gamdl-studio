#!/usr/bin/env bash
#
# Builds a signed, notarized DMG of Gamdl Studio.
#
#   scripts/release.sh            # version taken from project.yml
#   scripts/release.sh 1.2.0      # explicit version
#
# Requirements:
#   - Xcode, XcodeGen
#   - a "Developer ID Application" certificate in the login keychain
#   - notarization credentials, either:
#       NOTARY_PROFILE=<name>      a profile saved with `xcrun notarytool store-credentials`
#     or an App Store Connect API key:
#       NOTARY_KEY=<path to AuthKey_XXXX.p8> NOTARY_KEY_ID=<key id> NOTARY_ISSUER=<issuer id>
#
# Output: build/GamdlStudio-<version>.dmg

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
APP_NAME="GamdlStudio"
DISPLAY_NAME="Gamdl Studio"

VERSION="${1:-$(awk -F'"' '/MARKETING_VERSION/ { print $2; exit }' "$ROOT/project.yml")}"
[ -n "$VERSION" ] || { echo "Cannot read MARKETING_VERSION from project.yml" >&2; exit 1; }

IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')"
[ -n "$IDENTITY" ] || { echo "No Developer ID Application certificate found" >&2; exit 1; }
TEAM_ID="$(sed -E 's/.*\(([A-Z0-9]{10})\)$/\1/' <<<"$IDENTITY")"

notary_args() {
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    printf '%s\n' --keychain-profile "$NOTARY_PROFILE"
  elif [ -n "${NOTARY_KEY:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER:-}" ]; then
    printf '%s\n' --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER"
  else
    echo "Set NOTARY_PROFILE, or NOTARY_KEY + NOTARY_KEY_ID + NOTARY_ISSUER" >&2
    exit 1
  fi
}
NOTARY=()
while IFS= read -r arg; do NOTARY+=("$arg"); done < <(notary_args)

notarize() {
  echo "==> Notarizing $(basename "$1")"
  xcrun notarytool submit "$1" "${NOTARY[@]}" --wait --timeout 30m
}

echo "==> Gamdl Studio $VERSION, signed by $IDENTITY"
rm -rf "$BUILD"
mkdir -p "$BUILD"

cd "$ROOT"
xcodegen generate --quiet

echo "==> Archiving"
xcodebuild archive \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -archivePath "$BUILD/$APP_NAME.xcarchive" \
  -destination 'generic/platform=macOS' \
  MARKETING_VERSION="$VERSION" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  -quiet

APP="$BUILD/$APP_NAME.xcarchive/Products/Applications/$APP_NAME.app"
[ -d "$APP" ] || { echo "Archive failed: $APP not found" >&2; exit 1; }

BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[ "$BUNDLE_VERSION" = "$VERSION" ] || { echo "App reports version $BUNDLE_VERSION, expected $VERSION" >&2; exit 1; }

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements - --verbose=2 "$APP" 2>&1 | grep -E "Authority=Developer ID|flags=.*runtime" >/dev/null \
  || { echo "App is not signed with Developer ID and hardened runtime" >&2; exit 1; }

# Notarize and staple the app itself, so it stays valid once copied out of the DMG.
ditto -c -k --keepParent "$APP" "$BUILD/$APP_NAME.zip"
notarize "$BUILD/$APP_NAME.zip"
xcrun stapler staple "$APP"

echo "==> Building DMG"
STAGING="$BUILD/dmg"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/$DISPLAY_NAME.app"
ln -s /Applications "$STAGING/Applications"

DMG="$BUILD/$APP_NAME-$VERSION.dmg"
hdiutil create -volname "$DISPLAY_NAME" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
codesign --sign "$IDENTITY" --timestamp "$DMG"

notarize "$DMG"
xcrun stapler staple "$DMG"

echo "==> Gatekeeper check"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
spctl --assess --type execute --verbose=2 "$APP"

(cd "$BUILD" && shasum -a 256 "$(basename "$DMG")") | tee "$DMG.sha256"
echo "==> Done: $DMG"
