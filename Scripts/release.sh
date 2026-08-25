#!/bin/bash
# Build, notarize, staple, and package Hermternal.
#
# Scripts/ship.sh calls this file one stage at a time. The stage interface keeps
# the expensive Apple submission resumable while this file remains the single
# implementation of signing, notarization, stapling, and packaging.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

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

STAGE="all"
DRY_RUN=0
RESULT_FILE="${RELEASE_RESULT_FILE:-}"
RESUME_ID="${RELEASE_RESUME_ID:-}"
while (($# > 0)); do
	case "$1" in
		--stage)
			(($# >= 2)) || { printf 'error: --stage requires a value\n' >&2; if [[ "${SHIP_CHILD:-0}" != 1 ]]; then printf 'NEXT: A person at the Mac must rerun Scripts/ship.sh with a valid stage.\n' >&2; fi; exit 1; }
			STAGE="$2"
			shift 2
			;;
		--stage=*) STAGE="${1#*=}"; shift ;;
		--dry-run) DRY_RUN=1; shift ;;
		--resume-id)
			(($# >= 2)) || { printf 'error: --resume-id requires a value\n' >&2; if [[ "${SHIP_CHILD:-0}" != 1 ]]; then printf 'NEXT: A person at the Mac must rerun Scripts/ship.sh with a valid resume id.\n' >&2; fi; exit 1; }
			RESUME_ID="$2"
			shift 2
			;;
		--resume-id=*) RESUME_ID="${1#*=}"; shift ;;
		-h|--help)
			printf 'Usage: %s [--stage build|notarize|staple|package|verify-local] [--dry-run]\n' "${BASH_SOURCE[0]}"
			exit 0
			;;
		*) printf 'error: unknown argument: %s\n' "$1" >&2; if [[ "${SHIP_CHILD:-0}" != 1 ]]; then printf 'NEXT: A person at the Mac must rerun Scripts/ship.sh with a valid option.\n' >&2; fi; exit 1 ;;
	esac
done

case "$STAGE" in
	all|build|notarize|staple|package|verify-local) ;;
	*) printf 'error: unknown release stage: %s\n' "$STAGE" >&2; if [[ "${SHIP_CHILD:-0}" != 1 ]]; then printf 'NEXT: A person at the Mac must rerun Scripts/ship.sh with a valid stage.\n' >&2; fi; exit 1 ;;
esac

fail() {
	local message="$1"
	printf 'error: %s\n' "$message" >&2
	if [[ "${SHIP_CHILD:-0}" != 1 ]]; then
		printf 'NEXT: %s\n' "${NEXT_ACTION:-Stop and report this release failure to a person at the Mac.}"
	fi
	exit 1
}
trap 'printf "error: unexpected release command failure\n" >&2; if [[ "${SHIP_CHILD:-0}" != 1 ]]; then printf "NEXT: A person at the Mac must read the error above, fix that issue, and rerun Scripts/ship.sh.\n" >&2; fi' ERR

VERSION=""
if [[ -x /usr/libexec/PlistBuddy ]]; then
	VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist 2>/dev/null)" ||
		fail 'could not read CFBundleShortVersionString from Resources/Info.plist'
else
	fail 'PlistBuddy is unavailable; this script must run on a Mac'
fi
[[ -n "$VERSION" ]] || fail 'CFBundleShortVersionString is empty in Resources/Info.plist'
DIST="$ROOT/dist"
APP="$ROOT/build/Hermternal.app"
ZIP="$DIST/Hermternal-$VERSION.zip"
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

step() { printf '\n==> %s\n' "$1"; }
verify_signed_app() {
	[[ -d "$APP" ]] || fail 'signed app is missing; run the build stage first'
	local output expected_commit found_commit tree_clean configuration build_time build_info
	if ! output="$(codesign --verify --deep --strict "$APP" 2>&1)"; then
		printf '%s\n' "$output" >&2
		fail 'app bundle is not a valid signed build'
	fi
	expected_commit="$(git rev-parse HEAD 2>/dev/null)" ||
		fail 'could not resolve the current source commit'
	[[ -z "$(git status --porcelain=v1)" ]] ||
		fail 'source tree is dirty; refusing to release an untracked build'
	build_info="$APP/Contents/Resources/HermternalBuildInfo"
	[[ -f "$build_info" ]] ||
		fail 'signed app has no build provenance stamp; rebuild it before releasing'
	found_commit="$(sed -n 's/^commit=//p' "$build_info")"
	if [[ "$found_commit" != "$expected_commit" ]]; then
		fail "build commit mismatch: expected $expected_commit, found ${found_commit:-<missing>}"
	fi
	tree_clean="$(sed -n 's/^tree_clean=//p' "$build_info")"
	[[ "$tree_clean" == true ]] ||
		fail "build provenance is not clean (tree_clean=${tree_clean:-<missing>})"
	configuration="$(sed -n 's/^configuration=//p' "$build_info")"
	[[ "$configuration" == release ]] ||
		fail "build configuration mismatch: expected release, found ${configuration:-<missing>}"
	build_time="$(sed -n 's/^build_time=//p' "$build_info")"
	[[ -n "$build_time" ]] ||
		fail 'build provenance stamp has no build time'
}

CREDENTIAL_DIR="$HOME/.config/appstoreconnect"
SIGNING_P12_PATH="${CODESIGN_P12_PATH:-}"
SIGNING_PASSWORD_FILE="${CODESIGN_P12_PASSWORD_FILE:-}"
[[ "$SIGNING_P12_PATH" != "~/"* ]] || SIGNING_P12_PATH="$HOME/${SIGNING_P12_PATH#~/}"
[[ "$SIGNING_PASSWORD_FILE" != "~/"* ]] || SIGNING_PASSWORD_FILE="$HOME/${SIGNING_PASSWORD_FILE#~/}"
if [[ -z "$SIGNING_P12_PATH" && -d "$CREDENTIAL_DIR" ]]; then
	p12_count=0
	for candidate in "$CREDENTIAL_DIR"/*.p12; do
		[[ -f "$candidate" ]] || continue
		p12_count=$((p12_count + 1))
		SIGNING_P12_PATH="$candidate"
	done
	if (( p12_count > 1 )); then
		SIGNING_P12_PATH=""
		fail 'more than one portable signing .p12 is available'
	fi
fi
if [[ -z "$SIGNING_PASSWORD_FILE" && -n "$SIGNING_P12_PATH" &&
	-f "$CREDENTIAL_DIR/password.txt" ]]; then
	SIGNING_PASSWORD_FILE="$CREDENTIAL_DIR/password.txt"
fi
PORTABLE_SIGNING=0
if [[ -n "$SIGNING_P12_PATH" || -n "$SIGNING_PASSWORD_FILE" ]]; then
	PORTABLE_SIGNING=1
fi

EPHEMERAL_KEYCHAIN=""
KEYCHAIN_DIR=""
CODESIGN_SELECTOR=""
ORIGINAL_KEYCHAIN_BYTES=""
ORIGINAL_KEYCHAIN_COUNT=0
declare -a ORIGINAL_KEYCHAINS
cleanup_signing_keychain() {
	local status=$?
	trap - EXIT INT TERM
	if ! restore_keychain; then
		status=1
		if [[ "${SHIP_CHILD:-0}" != 1 ]]; then
			printf 'NEXT: A person at the Mac must inspect and restore the keychain search list before another release run.\n' >&2
		fi
	fi
	exit "$status"
}
restore_keychain() {
	local restored
	[[ -z "$EPHEMERAL_KEYCHAIN" ]] && return 0
	security list-keychains -s "${ORIGINAL_KEYCHAINS[@]}" >/dev/null 2>&1 || {
		printf 'error: could not restore the keychain search list; a person at the Mac must inspect the original plain security list-keychains output before another release run\n' >&2
		return 1
	}
	restored="$(security list-keychains 2>/dev/null)" || {
		printf 'error: could not read the restored plain keychain search list; stop before another release run\n' >&2
		return 1
	}
	if [[ "$restored" != "$ORIGINAL_KEYCHAIN_BYTES" ]]; then
		printf 'error: keychain search list was not restored byte-identically\n' >&2
		return 1
	fi
	security delete-keychain "$EPHEMERAL_KEYCHAIN" >/dev/null 2>&1 || true
	[[ -z "$KEYCHAIN_DIR" || ! -d "$KEYCHAIN_DIR" ]] || rm -rf "$KEYCHAIN_DIR"
	EPHEMERAL_KEYCHAIN=""
}
setup_signing_keychain() {
	[[ -n "${CODESIGN_IDENTITY:-}" ]] || fail 'CODESIGN_IDENTITY is unset; a person at the Mac must configure signing credentials before release.'
	case "$CODESIGN_IDENTITY" in
		"Developer ID Application"*) ;;
		*) fail 'CODESIGN_IDENTITY must be a Developer ID Application certificate.' ;;
	esac
	if (( ! PORTABLE_SIGNING )); then
		# The installed identity is the fallback when no portable files exist.
		local identities
		identities="$(security find-identity -v -p codesigning 2>&1)" ||
			fail 'cannot inspect installed signing identities'
		grep -qF "$CODESIGN_IDENTITY" <<<"$identities" ||
			fail 'installed Developer ID Application identity is unavailable'
		return 0
	fi
	if [[ ! -f "$SIGNING_P12_PATH" || ! -f "$SIGNING_PASSWORD_FILE" ]]; then
		NEXT_ACTION='A person at the Mac must provide one signing .p12 and its password file, then rerun Scripts/ship.sh.'
		fail 'portable signing credentials are missing'
	fi
	local keychain
	ORIGINAL_KEYCHAIN_BYTES="$(security list-keychains 2>/dev/null)" ||
		fail 'cannot capture the keychain search list'
	while IFS= read -r keychain; do
		keychain="${keychain#"${keychain%%[!$' \t\r\n']*}"}"
		keychain="${keychain#\"}"
		keychain="${keychain%\"}"
		if [[ -n "$keychain" ]]; then
			ORIGINAL_KEYCHAINS+=("$keychain")
			ORIGINAL_KEYCHAIN_COUNT=$((ORIGINAL_KEYCHAIN_COUNT + 1))
		fi
	done <<<"$ORIGINAL_KEYCHAIN_BYTES"
	(( ORIGINAL_KEYCHAIN_COUNT > 0 )) || fail 'cannot determine the keychain search list'
	KEYCHAIN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hermternal-signing.XXXXXX")" ||
		fail 'could not create a temporary signing directory'
	local keychain_password
	keychain_password="$(uuidgen)$(uuidgen)" || fail 'could not generate a temporary keychain password'
	EPHEMERAL_KEYCHAIN="$KEYCHAIN_DIR/signing-$RANDOM-$RANDOM.keychain-db"
	trap cleanup_signing_keychain EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	security create-keychain -p "$keychain_password" "$EPHEMERAL_KEYCHAIN" >/dev/null 2>&1 ||
		fail 'could not create the temporary signing keychain'
	chmod 600 "$EPHEMERAL_KEYCHAIN" || fail 'could not restrict the temporary signing keychain'
	security unlock-keychain -p "$keychain_password" "$EPHEMERAL_KEYCHAIN" >/dev/null 2>&1 ||
		fail 'could not unlock the temporary signing keychain'
	security import "$SIGNING_P12_PATH" -k "$EPHEMERAL_KEYCHAIN" -f pkcs12 -T /usr/bin/codesign \
		<"$SIGNING_PASSWORD_FILE" >/dev/null 2>&1 || fail 'could not import the portable signing identity'
	security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" \
		"$EPHEMERAL_KEYCHAIN" >/dev/null 2>&1 || fail 'could not grant codesign access to the temporary keychain'
	unset keychain_password
	security list-keychains -s "$EPHEMERAL_KEYCHAIN" "${ORIGINAL_KEYCHAINS[@]}" >/dev/null 2>&1 ||
		fail 'could not add the temporary signing keychain to the search list'
	local identities selector_info selector_count selector
	identities="$(security find-identity -v -p codesigning "$EPHEMERAL_KEYCHAIN" 2>&1)" ||
		fail 'cannot inspect identities in the temporary signing keychain'
	selector_info="$(
		sed -n 's/^[[:space:]]*[0-9]*)[[:space:]]*\([[:xdigit:]]\{40\}\)[[:space:]]*"\(.*\)"$/\1\t\2/p' \
			<<<"$identities" |
			awk -F '\t' -v identity="$CODESIGN_IDENTITY" \
				'$2 == identity { count++; selector = $1 } END { print count "\t" selector }'
	)"
	selector_count="${selector_info%%$'\t'*}"
	selector="${selector_info#*$'\t'}"
	if [[ "$selector_count" == 0 ]]; then
		fail 'portable signing identity was not found in the ephemeral keychain; check the certificate name and .p12'
	fi
	if [[ "$selector_count" != 1 || ! "$selector" =~ ^[[:xdigit:]]{40}$ ]]; then
		fail 'portable signing identity name is ambiguous in the ephemeral keychain; provide one matching Developer ID certificate'
	fi
	CODESIGN_SELECTOR="$selector"
}

run_build() {
	setup_signing_keychain
	step "Building release $VERSION"
	if (( PORTABLE_SIGNING )); then
		CONFIG=release CODESIGN_IDENTITY="$CODESIGN_SELECTOR" \
			CODESIGN_KEYCHAIN="$EPHEMERAL_KEYCHAIN" bash Scripts/build-app.sh ||
			fail 'the signed release build failed'
	else
		(
			unset CODESIGN_KEYCHAIN
			CONFIG=release CODESIGN_IDENTITY="$CODESIGN_IDENTITY" bash Scripts/build-app.sh
		) || fail 'the signed release build failed'
	fi
	verify_signed_app
}
run_notarize() {
	verify_signed_app
	mkdir -p "$DIST"
	step 'Packaging archive for Apple submission'
	rm -f "$ZIP"
	/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP" || fail 'could not package the archive for Apple submission'
	local digest output submission_id
	digest="$(shasum -a 256 "$ZIP" | cut -d ' ' -f 1)"
	step 'Submitting to Apple (this blocks until they answer)'
	output="$(xcrun notarytool submit "$ZIP" "${NOTARY_ARGS[@]}" --wait --output-format json 2>&1)" || {
		printf '%s\n' "$output" >&2
		fail 'Apple notarization failed'
	}
	printf '%s\n' "$output"
	if [[ "$output" =~ \"id\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
		submission_id="${BASH_REMATCH[1]}"
	else
		fail 'Apple accepted the archive but did not return a submission id'
	fi
	if [[ -n "$RESULT_FILE" ]]; then
		printf 'digest=%s\nsubmission_id=%s\n' "$digest" "$submission_id" >"$RESULT_FILE"
	fi
}
run_staple() {
	verify_signed_app
	step 'Stapling the ticket'
	xcrun stapler staple "$APP" || fail 'could not staple the notarization ticket'
	xcrun stapler validate "$APP" || fail 'stapled ticket did not validate'
	spctl --assess --type execute --verbose=2 "$APP" || fail 'Gatekeeper rejected the stapled app'
}
run_package() {
	mkdir -p "$DIST"
	verify_signed_app
	step 'Building final zip'
	rm -f "$ZIP"
	/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP" || fail 'could not build the final archive'
}
run_verify() {
	[[ -f "$ZIP" ]] || fail 'final archive is missing; run the package stage first'
	step 'Verifying final archive'
	bash Scripts/verify-notarization.sh "$ZIP" || fail 'final archive failed notarization verification'
}

if (( DRY_RUN )); then
	printf 'Dry run: release stage %s for version %s\n' "$STAGE" "$VERSION"
	exit 0
fi

case "$STAGE" in
	build) run_build ;;
	notarize) run_notarize ;;
	staple) run_staple ;;
	package) run_package ;;
	verify-local) run_verify ;;
	all)
		run_build
		run_notarize
		run_staple
		run_package
		run_verify
	;;
esac

printf 'Release stage complete: %s\n' "$STAGE"
