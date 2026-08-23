#!/bin/bash
# Build, sign, notarize, staple, and package Hermternal as a zip for distribution.
#
# Run Scripts/setup-signing.sh first for the normal interactive setup. For
# non-interactive SSH, set CODESIGN_P12_PATH and
# CODESIGN_P12_PASSWORD_FILE, or place one .p12 and password.txt under
# ~/.config/appstoreconnect. The release creates a temporary keychain from
# those files and removes it before exiting.
# Notarization uses ASC_KEY_PATH, ASC_KEY_ID, and ASC_ISSUER_ID from .env
# when present, or falls back to the stored notarytool profile.
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

# If a portable signing identity is available, import it into a fresh
# keychain. This avoids depending on the login keychain's GUI security
# session while retaining the existing login-keychain path as a fallback.
CREDENTIAL_DIR="$HOME/.config/appstoreconnect"
SIGNING_P12_PATH="${CODESIGN_P12_PATH:-}"
SIGNING_PASSWORD_FILE="${CODESIGN_P12_PASSWORD_FILE:-}"
if [[ "$SIGNING_P12_PATH" == "~/"* ]]; then
	SIGNING_P12_PATH="$HOME/${SIGNING_P12_PATH#~/}"
fi
if [[ "$SIGNING_PASSWORD_FILE" == "~/"* ]]; then
	SIGNING_PASSWORD_FILE="$HOME/${SIGNING_PASSWORD_FILE#~/}"
fi
if [[ -z "$SIGNING_P12_PATH" && -d "$CREDENTIAL_DIR" ]]; then
	p12_count=0
	for candidate in "$CREDENTIAL_DIR"/*.p12; do
		[[ -f "$candidate" ]] || continue
		p12_count=$((p12_count + 1))
		SIGNING_P12_PATH="$candidate"
	done
	(( p12_count == 1 )) || SIGNING_P12_PATH=""
fi
if [[ -z "$SIGNING_PASSWORD_FILE" &&
	-f "$CREDENTIAL_DIR/password.txt" ]]; then
	SIGNING_PASSWORD_FILE="$CREDENTIAL_DIR/password.txt"
fi

EPHEMERAL_KEYCHAIN=""
KEYCHAIN_DIR=""
declare -a ORIGINAL_KEYCHAINS=()
cleanup_signing_keychain() {
	local status=$?
	trap - EXIT INT TERM
	if [[ -n "$EPHEMERAL_KEYCHAIN" ]]; then
		if (( ${#ORIGINAL_KEYCHAINS[@]} > 0 )); then
			security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" \
				>/dev/null 2>&1 || printf \
				'warning: could not restore the keychain search list\n' >&2
		fi
		security delete-keychain "$EPHEMERAL_KEYCHAIN" >/dev/null 2>&1 || true
		if [[ -n "$KEYCHAIN_DIR" && -d "$KEYCHAIN_DIR" ]]; then
			rm -rf "$KEYCHAIN_DIR"
		fi
	fi
	exit "$status"
}
trap cleanup_signing_keychain EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

USE_EPHEMERAL_KEYCHAIN=0
if [[ -f "$SIGNING_P12_PATH" && -f "$SIGNING_PASSWORD_FILE" ]]; then
	USE_EPHEMERAL_KEYCHAIN=1
	KEYCHAIN_LIST="$(security list-keychains -d user 2>&1)" ||
		die "cannot capture the keychain search list"
	while IFS= read -r keychain; do
		keychain="${keychain#"${keychain%%[!$' \t\r\n']*}"}"
		keychain="${keychain#\"}"
		keychain="${keychain%\"}"
		[[ -n "$keychain" ]] && ORIGINAL_KEYCHAINS+=("$keychain")
	done <<<"$KEYCHAIN_LIST"
	[[ ${#ORIGINAL_KEYCHAINS[@]} -gt 0 ]] ||
		die "cannot determine the keychain search list"

	[[ -d "$CREDENTIAL_DIR" ]] ||
		die "signing credential directory is missing: $CREDENTIAL_DIR"
	KEYCHAIN_DIR="$(mktemp -d "$CREDENTIAL_DIR/.hermternal-signing.XXXXXX")" ||
		die "could not create a temporary signing directory"
	KEYCHAIN_PASSWORD="$(uuidgen)$(uuidgen)" ||
		die "could not generate a temporary keychain password"
	EPHEMERAL_KEYCHAIN="$KEYCHAIN_DIR/signing-$RANDOM-$RANDOM.keychain-db"
	if ! security create-keychain -p "$KEYCHAIN_PASSWORD" \
		"$EPHEMERAL_KEYCHAIN" >/dev/null 2>&1; then
		die "could not create the temporary signing keychain"
	fi
	if ! chmod 600 "$EPHEMERAL_KEYCHAIN"; then
		die "could not restrict the temporary signing keychain"
	fi
	if ! security unlock-keychain -p "$KEYCHAIN_PASSWORD" \
		"$EPHEMERAL_KEYCHAIN" >/dev/null 2>&1; then
		die "could not unlock the temporary signing keychain"
	fi
	if ! security import "$SIGNING_P12_PATH" -k "$EPHEMERAL_KEYCHAIN" \
		-f pkcs12 -T /usr/bin/codesign <"$SIGNING_PASSWORD_FILE" \
		>/dev/null 2>&1; then
		die "could not import the portable signing identity"
	fi
	if ! security set-key-partition-list \
		-S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" \
		"$EPHEMERAL_KEYCHAIN" >/dev/null 2>&1; then
		die "could not grant codesign access to the temporary keychain"
	fi
	unset KEYCHAIN_PASSWORD
	if ! security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" \
		"$EPHEMERAL_KEYCHAIN" >/dev/null 2>&1; then
		die "could not add the temporary signing keychain to the search list"
	fi
fi

if (( USE_EPHEMERAL_KEYCHAIN )); then
	IDENTITIES="$(security find-identity -v -p codesigning 2>&1)" ||
		die "cannot inspect identities in the temporary signing keychain"
	grep -qF "$CODESIGN_IDENTITY" <<<"$IDENTITIES" ||
		die "portable signing identity '$CODESIGN_IDENTITY' is unavailable"
else
	# The fallback is for local interactive builds using an installed
	# identity. The login keychain may be locked in a non-interactive shell.
	IDENTITIES="$(security find-identity -v -p codesigning 2>&1)" ||
		die "cannot inspect signing identities from the login keychain"
	grep -qF "$CODESIGN_IDENTITY" <<<"$IDENTITIES" ||
		die "codesign cannot reach '$CODESIGN_IDENTITY'. Unlock the login \
keychain in an interactive session, or provide CODESIGN_P12_PATH and \
CODESIGN_P12_PASSWORD_FILE for non-interactive signing."
fi
xcrun notarytool history "${NOTARY_ARGS[@]}" >/dev/null 2>&1 ||
	die "no usable notarytool credentials. Store profile '$NOTARY_PROFILE' with \
Scripts/setup-signing.sh, or set ASC_KEY_PATH/ASC_KEY_ID/ASC_ISSUER_ID in .env."

step "Building release $VERSION"
CONFIG=release CODESIGN_IDENTITY="$CODESIGN_IDENTITY" bash Scripts/build-app.sh

step "Verifying signature and hardened runtime"
codesign --verify --strict --verbose=2 "$APP"
# Capture diagnostics before parsing: pipefail must not hide codesign output.
SIGNATURE_INFO="$(codesign -d --verbose=2 "$APP" 2>&1)" ||
	die "could not inspect the signature"
SIGNATURE_LINES="$(grep -E '^(CodeDirectory|Signature=|TeamIdentifier)' \
	<<<"$SIGNATURE_INFO" || true)"
# Notarization is refused without the runtime flag, so fail here rather than
# after a multi-minute upload.
if ! grep -Eq '^CodeDirectory.*flags=.*\([^)]*runtime[^)]*\)' \
	<<<"$SIGNATURE_INFO"; then
	printf '%s\n' "$SIGNATURE_LINES" >&2
	die "hardened runtime missing from the signature"
fi
if grep -q '^Signature=adhoc$' <<<"$SIGNATURE_INFO" ||
	! grep -q '^TeamIdentifier=.' <<<"$SIGNATURE_INFO"; then
	printf '%s\n' "$SIGNATURE_LINES" >&2
	die "signature must be non-ad-hoc and include TeamIdentifier"
fi

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
step "Verifying final archive"
bash Scripts/verify-notarization.sh "$ZIP"

step "Done"
shasum -a 256 "$ZIP"
printf '\nRelease %s ready in %s\n' "$VERSION" "$DIST"
