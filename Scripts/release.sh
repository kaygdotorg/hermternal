#!/bin/bash
# Build, sign, notarize, staple, and package Hermternal for distribution.
#
# Run Scripts/setup-signing.sh first: this script needs a Developer ID
# Application identity in the keychain and a stored notarytool profile.
#
# Notarization uploads the app to Apple and blocks until they answer, so this
# takes minutes, not seconds. Stapling writes the resulting ticket into the
# bundle so Gatekeeper clears it without a network round trip on first launch.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
[[ -f .env ]] && set -a && . ./.env && set +a

NOTARY_PROFILE="${NOTARY_PROFILE:-hermternal}"
VERSION="$(
	/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
		Resources/Info.plist
)"
DIST="$ROOT/dist"
APP="$ROOT/build/Hermternal.app"
ZIP="$DIST/Hermternal-$VERSION.zip"
DMG="$DIST/Hermternal-$VERSION.dmg"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
step() { printf '\n==> %s\n' "$1"; }

[[ -n "${CODESIGN_IDENTITY:-}" ]] ||
	die "CODESIGN_IDENTITY unset. Run Scripts/setup-signing.sh."
case "$CODESIGN_IDENTITY" in
	"Developer ID Application"*) ;;
	*) die "CODESIGN_IDENTITY must be a 'Developer ID Application' certificate; \
Apple rejects anything else for notarized distribution. Got: $CODESIGN_IDENTITY" ;;
esac
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 ||
	die "no notarytool profile '$NOTARY_PROFILE'. Run Scripts/setup-signing.sh."

step "Building release $VERSION"
CONFIG=release CODESIGN_IDENTITY="$CODESIGN_IDENTITY" bash Scripts/build-app.sh

step "Verifying signature and hardened runtime"
codesign --verify --strict --verbose=2 "$APP"
# Notarization is refused without the runtime flag, so fail here rather than
# after a multi-minute upload.
codesign -d --verbose=2 "$APP" 2>&1 | grep -q 'flags=.*runtime' ||
	die "hardened runtime missing from the signature"

step "Packaging for submission"
rm -rf "$DIST"
mkdir -p "$DIST"
# ditto preserves the bundle's symlinks and extended attributes; `zip` does
# not, and Apple rejects a bundle flattened by `zip`.
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

step "Submitting to Apple (this blocks until they answer)"
xcrun notarytool submit "$ZIP" \
	--keychain-profile "$NOTARY_PROFILE" \
	--wait

step "Stapling the ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

step "Confirming Gatekeeper accepts it"
spctl --assess --type execute --verbose=2 "$APP"

step "Building distributables"
# Re-zip after stapling: the earlier archive predates the ticket.
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
hdiutil create -quiet -fs HFS+ -volname "Hermternal $VERSION" \
	-srcfolder "$APP" -ov -format UDZO "$DMG"
codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

step "Done"
shasum -a 256 "$ZIP" "$DMG"
printf '\nRelease %s ready in %s\n' "$VERSION" "$DIST"
