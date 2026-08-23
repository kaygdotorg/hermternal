#!/bin/bash
# One unattended, resumable release command.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
FORGEJO_HOST="${FORGEJO_HOST:-https://git.kayg.org}"
FORGEJO_HOST="${FORGEJO_HOST%/}"
FORGEJO_REPO="kayg/hermternal-apple"
REPLACE_ASSET=0
DRY_RUN=0

fail() {
	printf 'error: %s\n' "$1" >&2
	printf 'NEXT: %s\n' "$2" >&2
	exit 1
}
trap 'printf "error: unexpected release command failure\n" >&2; printf "NEXT: A person at the Mac must read the error above, fix that issue, and rerun Scripts/ship.sh.\n" >&2' ERR
while (($# > 0)); do
	case "$1" in
		--replace-asset) REPLACE_ASSET=1; shift ;;
		--dry-run) DRY_RUN=1; shift ;;
		-h|--help)
			printf 'Usage: %s [--replace-asset] [--dry-run]\n' "${BASH_SOURCE[0]}"
			exit 0
			;;
		*) fail "unknown argument: $1" 'A person at the Mac must run Scripts/ship.sh with --help, then rerun with a valid option.' ;;
	esac
done

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
				first="${value:0:1}"; last="${value: -1}"
				if [[ ( "$first" == "'" && "$last" == "'" ) || ( "$first" == '"' && "$last" == '"' ) ]]; then
					value="${value:1:${#value}-2}"
				fi
			fi
			export "$key=$value"
		fi
	done < "$file"
}
[[ -f .env ]] && load_env .env
if [[ "${ASC_KEY_PATH:-}" == "~/"* ]]; then ASC_KEY_PATH="$HOME/${ASC_KEY_PATH#~/}"; export ASC_KEY_PATH; fi

if [[ ! -x /usr/libexec/PlistBuddy ]]; then
	fail 'PlistBuddy is unavailable; this command must run on a Mac.' 'A person at the Mac must run Scripts/ship.sh on the release checkout.'
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist 2>/dev/null)" ||
	fail 'could not read CFBundleShortVersionString from Resources/Info.plist' 'A person at the Mac must repair Resources/Info.plist, commit it, and rerun Scripts/ship.sh.'
[[ -n "$VERSION" ]] || fail 'CFBundleShortVersionString is empty' 'A person at the Mac must set Resources/Info.plist before rerunning Scripts/ship.sh.'
TAG="v$VERSION"
HEAD="$(git rev-parse HEAD 2>/dev/null)" || fail 'could not resolve HEAD' 'A person at the Mac must run Scripts/ship.sh from a Git checkout.'
DIST="$ROOT/dist"
STATE="$DIST/.ship"
ZIP="$DIST/Hermternal-$VERSION.zip"
APP="$ROOT/build/Hermternal.app"
META="$STATE/meta.env"
# Every marker starts with the checkout identity. Publish markers also record
# the artifact digest and operation, so only the same replacement can resume.
stage_marker() { printf '%s/%s.done' "$STATE" "$1"; }
stage_done() {
	local marker first
	marker="$(stage_marker "$1")"
	[[ -f "$marker" ]] || return 1
	IFS= read -r first <"$marker"
	[[ "$first" == "$HEAD:$VERSION" ]]
}
marker_fact_matches() {
	local marker="$1" key="$2" expected="$3"
	grep -qxF "$key=$expected" "$marker"
}
mark_stage() {
	local stage="$1" digest="${2:-}" operation="${3:-}"
	printf '%s\n' "$HEAD:$VERSION" >"$(stage_marker "$stage")"
	[[ -z "$digest" ]] || printf 'artifact_digest=%s\n' "$digest" >>"$(stage_marker "$stage")"
	[[ -z "$operation" ]] || printf 'operation=%s\n' "$operation" >>"$(stage_marker "$stage")"
}
clear_later_stages() {
	local stage="$1" seen=0 name
	for name in preflight build notarize staple package verify-local tag publish verify-published; do
		[[ "$name" == "$stage" ]] && seen=1
		if (( seen )); then rm -f "$(stage_marker "$name")"; fi
	done
}

# A new commit or version invalidates every old marker. State never controls a
# different source tree. Dry runs do not create or modify state.
if (( DRY_RUN )); then
	printf 'Dry run for version %s (tag %s)\n' "$VERSION" "$TAG"
	for stage in preflight build notarize staple package verify-local tag publish verify-published; do
		if stage_done "$stage"; then printf 'SKIP %s (completed for this checkout)\n' "$stage"; else printf 'RUN  %s\n' "$stage"; fi
	done
	exit 0
fi
mkdir -p "$DIST" 2>/dev/null || fail 'could not create dist' 'A person at the Mac must make the checkout writable, then rerun Scripts/ship.sh.'
mkdir -p "$STATE" 2>/dev/null || fail 'could not create release state' 'A person at the Mac must make dist writable, then rerun Scripts/ship.sh.'
if [[ -f "$META" ]] && { ! grep -qF "head=$HEAD" "$META" || ! grep -qF "version=$VERSION" "$META"; }; then
	clear_later_stages preflight
	rm -f "$STATE/notary.env" "$STATE/submitted.zip" "$STATE/published.zip"
fi
printf 'head=%s\nversion=%s\ntag=%s\n' "$HEAD" "$VERSION" "$TAG" >"$META"

# Recheck the two inputs that can change after preflight. State may skip slow
# work, but it must never bless a newly dirty tree or an existing release
# without the explicit replacement flag.
if stage_done preflight; then
	[[ -z "$(git status --porcelain=v1)" ]] || fail 'working tree is dirty' 'A person at the Mac must commit or stash all changes, then rerun Scripts/ship.sh.'
	API_URL="$FORGEJO_HOST/api/v1/repos/$FORGEJO_REPO/releases/tags/$TAG"
	API_STATUS="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' "$API_URL" 2>/dev/null)" || fail 'could not query Forgejo releases' 'A person at the Mac must restore network access to Forgejo, then rerun Scripts/ship.sh.'
	if [[ "$API_STATUS" == 200 && "$REPLACE_ASSET" != 1 && ! -f "$(stage_marker publish)" ]]; then
		fail "release $TAG already exists" 'A person at the Mac must rerun Scripts/ship.sh with --replace-asset to replace only its zip.'
	fi
	[[ "$API_STATUS" == 200 || "$API_STATUS" == 404 ]] || fail "Forgejo release lookup returned HTTP $API_STATUS" 'A person at the Mac must repair Forgejo access, then rerun Scripts/ship.sh.'
fi

# Preflight checks the checkout, credentials, and release target before build.
if ! stage_done preflight; then
	[[ -z "$(git status --porcelain=v1)" ]] || fail 'working tree is dirty' 'A person at the Mac must commit or stash all changes, then rerun Scripts/ship.sh.'
	BRANCH="$(git symbolic-ref --quiet --short HEAD || true)"
	[[ -n "$BRANCH" ]] || fail 'HEAD is detached' 'A person at the Mac must check out the release branch, then rerun Scripts/ship.sh.'
	REMOTE_HEAD="$(git ls-remote --heads origin "refs/heads/$BRANCH" 2>/dev/null)" || fail 'could not query origin' 'A person at the Mac must restore network access to origin, then rerun Scripts/ship.sh.'
	REMOTE_HEAD="${REMOTE_HEAD%%$'\t'*}"
	if local_tag="$(git rev-parse --verify --quiet "refs/tags/$TAG" 2>/dev/null)"; then
		[[ "$local_tag" == "$HEAD" ]] || fail "tag $TAG points away from HEAD" 'A person at the Mac must resolve the tag mismatch before rerunning Scripts/ship.sh.'
	fi
	REMOTE_TAG="$(git ls-remote --tags --refs origin "refs/tags/$TAG" 2>/dev/null)" || fail 'could not query origin tags' 'A person at the Mac must restore network access to origin, then rerun Scripts/ship.sh.'
	REMOTE_TAG="${REMOTE_TAG%%$'\t'*}"
	[[ -z "$REMOTE_TAG" || "$REMOTE_TAG" == "$HEAD" ]] || fail "tag $TAG points away from HEAD on origin" 'A person at the Mac must resolve the remote tag mismatch before rerunning Scripts/ship.sh.'
	[[ "$REMOTE_HEAD" == "$HEAD" ]] || fail 'HEAD is not pushed to origin' 'A person at the Mac must push HEAD to origin, then rerun Scripts/ship.sh.'
	[[ -n "${CODESIGN_IDENTITY:-}" ]] || fail 'CODESIGN_IDENTITY is unset' 'A person at the Mac must configure .env signing credentials, then rerun Scripts/ship.sh.'
	[[ "$CODESIGN_IDENTITY" == Developer\ ID\ Application:* ]] || fail 'CODESIGN_IDENTITY is not a Developer ID Application identity' 'A person at the Mac must set the correct identity in .env, then rerun Scripts/ship.sh.'
	NOTARY_PROFILE="${NOTARY_PROFILE:-hermternal}"
	if [[ -n "${ASC_KEY_PATH:-}" && -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" && -f "$ASC_KEY_PATH" ]]; then
		xcrun notarytool history --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" >/dev/null 2>&1 || fail 'notarytool credentials are unusable' 'A person at the Mac must repair App Store Connect credentials, then rerun Scripts/ship.sh.'
	else
		xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || fail 'notarytool credentials are unusable' 'A person at the Mac must configure the notarytool profile, then rerun Scripts/ship.sh.'
	fi
	CREDENTIAL_DIR="$HOME/.config/appstoreconnect"
	p12="${CODESIGN_P12_PATH:-}"
	password_file="${CODESIGN_P12_PASSWORD_FILE:-}"
	[[ "$p12" != "~/"* ]] || p12="$HOME/${p12#~/}"
	[[ "$password_file" != "~/"* ]] || password_file="$HOME/${password_file#~/}"
	if [[ -z "$p12" && -d "$CREDENTIAL_DIR" ]]; then
		shopt -s nullglob
		p12s=("$CREDENTIAL_DIR"/*.p12)
		shopt -u nullglob
		if ((${#p12s[@]} > 1)); then
			fail 'exactly one signing .p12 is required' 'A person at the Mac must provide exactly one signing .p12, then rerun Scripts/ship.sh.'
		elif ((${#p12s[@]} == 1)); then
			p12="${p12s[0]}"
		fi
	fi
	[[ -n "$password_file" || -z "$p12" ]] || password_file="$CREDENTIAL_DIR/password.txt"
	if [[ -n "$p12" || -n "$password_file" ]]; then
		[[ -f "$p12" && -f "$password_file" ]] || fail 'signing .p12 or password file is missing' 'A person at the Mac must provide the .p12 and password file, then rerun Scripts/ship.sh.'
	else
		# The installed identity check is only the fallback when no portable
		# signing credentials exist. Portable credentials are imported later.
		identities="$(security find-identity -v -p codesigning 2>/dev/null)" ||
			fail 'Developer ID Application identity lookup failed' 'A person at the Mac must make the signing identity reachable, then rerun Scripts/ship.sh.'
		grep -qF "$CODESIGN_IDENTITY" <<<"$identities" ||
			fail 'Developer ID Application identity is unreachable' 'A person at the Mac must make the signing identity reachable, then rerun Scripts/ship.sh.'
	fi
	API_URL="$FORGEJO_HOST/api/v1/repos/$FORGEJO_REPO/releases/tags/$TAG"
	API_STATUS="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' "$API_URL" 2>/dev/null)" || fail 'could not query Forgejo releases' 'A person at the Mac must restore Forgejo network access, then rerun Scripts/ship.sh.'
	if [[ "$API_STATUS" == 200 && "$REPLACE_ASSET" != 1 ]]; then
		fail "release $TAG already exists" 'A person at the Mac must rerun Scripts/ship.sh with --replace-asset to replace only its zip.'
	fi
	[[ "$API_STATUS" == 200 || "$API_STATUS" == 404 ]] || fail "Forgejo release lookup returned HTTP $API_STATUS" 'A person at the Mac must repair Forgejo access, then rerun Scripts/ship.sh.'
	mark_stage preflight
fi

run_stage() {
	local stage="$1"; shift
	if stage_done "$stage"; then
		printf 'SKIP %s\n' "$stage"
		return 0
	fi
	printf 'RUN %s\n' "$stage"
	local output
	if ! output="$(SHIP_CHILD=1 "$@" 2>&1)"; then
		printf '%s\n' "$output" >&2
		fail "$stage stage failed" "A person at the Mac must read the error above, fix that issue, and rerun Scripts/ship.sh."
	fi
	printf '%s\n' "$output"
	if [[ "$stage" == publish ]]; then
		mark_stage "$stage" "$FINAL_DIGEST" "$PUBLISH_OPERATION"
	else
		mark_stage "$stage"
	fi
}

confirm_submission() {
	local output
	if [[ -n "${ASC_KEY_PATH:-}" && -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" && -f "$ASC_KEY_PATH" ]]; then
		output="$(xcrun notarytool info "$submission_id" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --output-format json 2>&1)" ||
			fail 'could not confirm the accepted Apple submission' 'A person at the Mac must restore notarytool network access, then rerun Scripts/ship.sh.'
	else
		output="$(xcrun notarytool info "$submission_id" --keychain-profile "$NOTARY_PROFILE" --output-format json 2>&1)" ||
			fail 'could not confirm the accepted Apple submission' 'A person at the Mac must restore notarytool network access, then rerun Scripts/ship.sh.'
	fi
	[[ "$output" =~ [Aa]ccepted ]] ||
		fail 'the saved Apple submission is not accepted' 'A person at the Mac must inspect the Apple submission result before rerunning Scripts/ship.sh.'
}

# The build stage owns the signed app. Its marker is valid only while that
# app exists, so notarization cannot resume against missing or stale output.
if stage_done build && [[ ! -d "$APP" ]]; then
	clear_later_stages build
fi
run_stage build bash Scripts/release.sh --stage build
[[ -d "$APP" ]] || fail 'build stage completed without a signed app' 'A person at the Mac must inspect the build output, then rerun Scripts/ship.sh.'

# A changed final archive invalidates the accepted-submission evidence before
# any resume check. The next notarize stage rebuilds and submits a fresh input.
if stage_done package && [[ -f "$ZIP" && -f "$STATE/final.digest" ]]; then
	current_digest="$(shasum -a 256 "$ZIP" | cut -d ' ' -f 1)"
	if [[ "$current_digest" != "$(<"$STATE/final.digest")" ]]; then
		clear_later_stages notarize
		rm -f "$STATE/notary.env" "$STATE/submitted.zip"
	fi
fi

# Keep the exact pre-stapling archive digest and Apple id. A final stapled zip
# has a different digest, so it is tracked separately below.
if stage_done notarize; then
	if [[ -f "$STATE/notary.env" && -f "$STATE/submitted.zip" ]]; then
		# shellcheck disable=SC1090
		source "$STATE/notary.env"
		submitted_digest="$(shasum -a 256 "$STATE/submitted.zip" | cut -d ' ' -f 1)"
		if [[ "${submitted_digest:-}" == "${digest:-}" ]]; then
			NOTARY_PROFILE="${NOTARY_PROFILE:-hermternal}"
			confirm_submission
			printf 'SKIP notarize (Apple submission %s already accepted)\n' "$submission_id"
		else
			clear_later_stages notarize
		fi
	else
		clear_later_stages notarize
	fi
fi
if ! stage_done notarize; then
	rm -f "$STATE/notary.env" "$STATE/submitted.zip"
	export RELEASE_RESULT_FILE="$STATE/notary.env"
	run_stage notarize bash Scripts/release.sh --stage notarize
	unset RELEASE_RESULT_FILE
	cp "$ZIP" "$STATE/submitted.zip"
fi
run_stage staple bash Scripts/release.sh --stage staple
run_stage package bash Scripts/release.sh --stage package

# A changed final archive invalidates all later evidence, including publication.
FINAL_DIGEST="$(shasum -a 256 "$ZIP" | cut -d ' ' -f 1)"
if [[ -f "$STATE/final.digest" && "$(<"$STATE/final.digest")" != "$FINAL_DIGEST" ]]; then
	clear_later_stages verify-local
fi
printf '%s\n' "$FINAL_DIGEST" >"$STATE/final.digest"
run_stage verify-local bash Scripts/release.sh --stage verify-local
run_stage tag bash Scripts/publish.sh --tag-only
PUBLISH_OPERATION=create
if (( REPLACE_ASSET )); then
	PUBLISH_OPERATION=replace
	if stage_done publish &&
		! marker_fact_matches "$(stage_marker publish)" artifact_digest "$FINAL_DIGEST"; then
		clear_later_stages publish
	elif stage_done publish &&
		! marker_fact_matches "$(stage_marker publish)" operation replace; then
		# A replacement request must not inherit a normal publish marker.
		clear_later_stages publish
	fi
fi
if stage_done verify-published &&
	! marker_fact_matches "$(stage_marker verify-published)" artifact_digest "$FINAL_DIGEST"; then
	rm -f "$(stage_marker verify-published)"
fi
PUBLISH_ARGS=(--skip-tag)
if (( REPLACE_ASSET )); then
	PUBLISH_ARGS=(--replace-asset --skip-tag)
fi
run_stage publish bash Scripts/publish.sh "${PUBLISH_ARGS[@]}"
if ! stage_done verify-published; then
	printf 'RUN verify-published\n'
	PUBLISHED="$STATE/published.zip"
	curl --fail --silent --show-error --location \
		--output "$PUBLISHED" "$FORGEJO_HOST/$FORGEJO_REPO/releases/download/$TAG/Hermternal-$VERSION.zip" ||
		fail 'could not download the published archive' 'A person at the Mac must restore Forgejo network access, then rerun Scripts/ship.sh.'
	bash Scripts/verify-notarization.sh "$PUBLISHED" ||
		fail 'published archive failed notarization verification' 'A person at the Mac must stop and report the published-archive failure to a person at the Mac.'
	PUBLISHED_DIGEST="$(shasum -a 256 "$PUBLISHED" | cut -d ' ' -f 1)"
	[[ "$PUBLISHED_DIGEST" == "$FINAL_DIGEST" ]] || fail 'published archive digest differs from the verified local archive' 'A person at the Mac must stop; do not retry publishing until Forgejo is inspected.'
	mark_stage verify-published "$FINAL_DIGEST" "$PUBLISH_OPERATION"
else
	PUBLISHED_DIGEST="$(shasum -a 256 "$STATE/published.zip" | cut -d ' ' -f 1)"
fi
printf 'DONE: %s/releases/tag/%s sha256=%s\n' "$FORGEJO_HOST/$FORGEJO_REPO" "$TAG" "$PUBLISHED_DIGEST"
