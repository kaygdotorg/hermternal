#!/bin/bash
# Verify that a macOS app or zip is fully notarized and accepted by Gatekeeper.
#
# A zip is extracted before checking: Apple's stapled ticket lives inside the
# app bundle, not beside the archive.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

(($# == 1)) || die "usage: $0 path-to-app-or-zip"
INPUT="$1"
[[ -e "$INPUT" ]] || die "path does not exist: $INPUT"

VERIFY_DIR=''
cleanup() {
	[[ -z "$VERIFY_DIR" ]] || rm -rf "$VERIFY_DIR"
}
trap cleanup EXIT

if [[ "$INPUT" == *.zip ]]; then
	VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hermternal-verify.XXXXXX")"
	/usr/bin/ditto -x -k "$INPUT" "$VERIFY_DIR" ||
		die 'could not extract zip archive'

	shopt -s nullglob
	APPS=("$VERIFY_DIR"/*.app "$VERIFY_DIR"/*/*.app)
	shopt -u nullglob
	((${#APPS[@]} == 1)) ||
		die "zip must contain exactly one app bundle (found ${#APPS[@]})"
	APP="${APPS[0]}"
elif [[ -d "$INPUT" && "$INPUT" == *.app ]]; then
	APP="$INPUT"
else
	die 'input must be a .zip archive or .app bundle'
fi

printf 'Verifying notarization: %s\n' "$APP"

codesign --verify --strict --verbose=2 "$APP" ||
	die 'codesign verification failed'

SIGNATURE_INFO="$(codesign -d --verbose=4 "$APP" 2>&1)" || {
	printf '%s\n' "$SIGNATURE_INFO" >&2
	die 'could not inspect the code signature'
}
SIGNATURE_LINES="$(printf '%s\n' "$SIGNATURE_INFO" |
	grep -E '^(Authority|CodeDirectory|Signature=|TeamIdentifier|Timestamp=)' || true)"

if ! grep -Eq '^Authority=Developer ID Application: .+ \([^)]+\)$' \
	<<<"$SIGNATURE_INFO"; then
	printf '%s\n' "$SIGNATURE_LINES" >&2
	die 'signature is not a Developer ID Application certificate'
fi
if grep -Eq '^Signature=adhoc$' <<<"$SIGNATURE_INFO"; then
	printf '%s\n' "$SIGNATURE_LINES" >&2
	die 'signature is ad-hoc'
fi
if ! grep -Eq '^TeamIdentifier=[^[:space:]]+$' <<<"$SIGNATURE_INFO"; then
	printf '%s\n' "$SIGNATURE_LINES" >&2
	die 'signature has no Team Identifier'
fi
if ! grep -Eq '^CodeDirectory.*flags=.*\([^)]*runtime[^)]*\)' \
	<<<"$SIGNATURE_INFO"; then
	printf '%s\n' "$SIGNATURE_LINES" >&2
	die 'signature does not have the hardened runtime flag'
fi
if ! grep -Eq '^Timestamp=.+$' <<<"$SIGNATURE_INFO"; then
	printf '%s\n' "$SIGNATURE_LINES" >&2
	die 'signature has no secure timestamp'
fi

xcrun stapler validate "$APP" ||
	die 'app has no valid stapled notarization ticket'
spctl -a -t exec "$APP" ||
	die 'Gatekeeper rejected the app'

printf 'Notarization verified: Developer ID, hardened runtime, secure timestamp, stapled ticket, and Gatekeeper acceptance.\n'
