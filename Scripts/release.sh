#!/bin/bash
# Build, sign, notarize, staple, and package Hermternal as a zip for distribution.
#
# Run Scripts/setup-signing.sh first: this script needs a Developer ID
# Application identity in the keychain. Notarization uses ASC_KEY_PATH,
# ASC_KEY_ID, and ASC_ISSUER_ID from .env when present, or falls back to
# the stored notarytool profile. Run codesign in the Mac's own login session;
# the private-key ACL cannot prompt over ssh.
#
# Notarization uploads the app to Apple and blocks until they answer, so this
# takes minutes, not seconds. Stapling writes the resulting ticket into the
# bundle so Gatekeeper clears it without a network round trip on first launch.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Do not source .env: a signing identity legitimately contains parentheses, so
# .env cannot be assumed to be valid shell.
load_env() {
	local file="$1" line trimmed key value first last
	while IFS= read -r line || [[ -n "$line" ]]; do
		trimmed="${line#"${line%%[!$' \t\r\n']*}"}"
		[[ -z "$trimmed" || "$trimmed" == \#* ]] && continue
		[[ "$trimmed" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
		key="${BASH_REMATCH[1]}"
		value="${BASH_REMATCH[2]}"
		if [[ -z "${!key+x}" ]]; then
			if (( ${#value} >= 2 )); then
				first="${value:0:1}"
				last="${value: -1}"
				if [[ ( "$first" == "'" && "$last" == "'" ) ||
					( "$first" == '"' && "$last" == '"' ) ]]; then
					value="${value:1:${#value}-2}"
				fi
			fi
			export "$key=$value"
		fi
	done < "$file"
}

[[ -f .env ]] && load_env .env

NOTARY_PROFILE="${NOTARY_PROFILE:-hermternal}"
if [[ "${ASC_KEY_PATH:-}" == "~/"* ]]; then
	ASC_KEY_PATH="$HOME/${ASC_KEY_PATH#~/}"
	export ASC_KEY_PATH
fi
if [[ -n "${ASC_KEY_PATH:-}" && -n "${ASC_KEY_ID:-}" &&
	-n "${ASC_ISSUER_ID:-}" && -f "$ASC_KEY_PATH" ]]; then
	NOTARY_ARGS=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
else
	NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
fi

VERSION="$(
	/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
		Resources/Info.plist
)"
DIST="$ROOT/dist"
APP="$ROOT/build/Hermternal.app"
ZIP="$DIST/Hermternal-$VERSION.zip"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
step() { printf '\n==> %s\n' "$1"; }

[[ -n "${CODESIGN_IDENTITY:-}" ]] ||
	die "CODESIGN_IDENTITY unset. Run Scripts/setup-signing.sh."
case "$CODESIGN_IDENTITY" in
	"Developer ID Application"*) ;;
	*) die "CODESIGN_IDENTITY must be a 'Developer ID Application' certificate; \
Apple rejects anything else for notarized distribution. Got: $CODESIGN_IDENTITY" ;;
esac

# The private key lives in the login keychain, which only the Mac's own login
# session can unlock. Over ssh the Security framework cannot prompt and
# codesign fails with "User interaction is not allowed" -- after the build.
# Check up front instead.
security find-identity -v -p codesigning 2>/dev/null |
	grep -qF "$CODESIGN_IDENTITY" ||
	die "codesign cannot reach '$CODESIGN_IDENTITY'. The login keychain is \
locked or unreadable. Run this from Terminal.app on the Mac, not over ssh; \
or unlock first with: security unlock-keychain"
xcrun notarytool history "${NOTARY_ARGS[@]}" >/dev/null 2>&1 ||
	die "no usable notarytool credentials. Store profile '$NOTARY_PROFILE' with \
Scripts/setup-signing.sh, or set ASC_KEY_PATH/ASC_KEY_ID/ASC_ISSUER_ID in .env."

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
	"${NOTARY_ARGS[@]}" \
	--wait

step "Stapling the ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

step "Confirming Gatekeeper accepts it"
spctl --assess --type execute --verbose=2 "$APP"

step "Building final zip"
# Re-zip after stapling: the earlier archive predates the ticket.
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

step "Done"
shasum -a 256 "$ZIP"
printf '\nRelease %s ready in %s\n' "$VERSION" "$DIST"
