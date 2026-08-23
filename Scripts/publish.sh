#!/bin/bash
# Create or replace the Forgejo release asset for a notarized archive.
#
# Scripts/ship.sh calls this file after local verification. The Forgejo API is
# used only to resolve the release name; fj uses its existing credentials for
# writes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
FORGEJO_HOST="${FORGEJO_HOST:-https://git.kayg.org}"
FORGEJO_HOST="${FORGEJO_HOST%/}"
FORGEJO_REPO="kayg/hermternal-apple"
ALLOW_DIRTY="${PUBLISH_ALLOW_DIRTY:-0}"
ALLOW_UNPUSHED="${PUBLISH_ALLOW_UNPUSHED:-0}"
REPLACE_ASSET=0
TAG_ONLY=0
SKIP_TAG=0
NOTES_FILE=""

usage() {
	printf 'Usage: %s [--replace-asset] [--skip-tag|--tag-only] [--notes-file PATH]\n' "${BASH_SOURCE[0]}"
	printf 'Create a release or replace only Hermternal-<version>.zip in an existing release.\n'
}
fail() {
	printf 'error: %s\n' "$1" >&2
	if [[ "${SHIP_CHILD:-0}" != 1 ]]; then
		printf 'NEXT: %s\n' "${NEXT_ACTION:-Stop and report this publishing failure to a person at the Mac.}"
	fi
	exit 1
}
trap 'printf "error: unexpected publishing command failure\n" >&2; if [[ "${SHIP_CHILD:-0}" != 1 ]]; then printf "NEXT: A person at the Mac must read the error above, fix that issue, and rerun Scripts/ship.sh.\n" >&2; fi' ERR
while (($# > 0)); do
	case "$1" in
		--replace-asset) REPLACE_ASSET=1; shift ;;
		--tag-only) TAG_ONLY=1; shift ;;
		--skip-tag) SKIP_TAG=1; shift ;;
		--notes-file)
			(($# >= 2)) || fail '--notes-file requires a path'
			NOTES_FILE="$2"; shift 2 ;;
		--notes-file=*) NOTES_FILE="${1#*=}"; [[ -n "$NOTES_FILE" ]] || fail '--notes-file requires a path'; shift ;;
		-h|--help) usage; exit 0 ;;
		*) fail "unknown argument: $1" ;;
	esac
done

if [[ -x /usr/libexec/PlistBuddy ]]; then
	VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist 2>/dev/null)" ||
		fail 'could not read CFBundleShortVersionString from Resources/Info.plist'
else
	fail 'PlistBuddy is unavailable; this script must run on a Mac'
fi
[[ -n "$VERSION" ]] || fail 'CFBundleShortVersionString is empty in Resources/Info.plist'
TAG="v$VERSION"
ZIP="$ROOT/dist/Hermternal-$VERSION.zip"
[[ -f "$ZIP" ]] || fail "release artifact is missing: dist/Hermternal-$VERSION.zip"
bash "$ROOT/Scripts/verify-notarization.sh" "$ZIP" || fail 'release artifact failed notarization verification'

if [[ "$ALLOW_DIRTY" != 1 ]]; then
	[[ -z "$(git status --porcelain=v1)" ]] || fail 'working tree is dirty; commit or stash changes before publishing'
fi
HEAD="$(git rev-parse HEAD)"
BRANCH="$(git symbolic-ref --quiet --short HEAD || true)"
if [[ "$ALLOW_UNPUSHED" != 1 ]]; then
	[[ -n "$BRANCH" ]] || fail 'HEAD is detached and cannot be verified as pushed to origin'
	REMOTE_HEAD="$(git ls-remote --heads origin "refs/heads/$BRANCH" 2>/dev/null)" ||
		fail 'could not verify whether HEAD is pushed to origin'
	REMOTE_HEAD="${REMOTE_HEAD%%$'\t'*}"
	[[ "$REMOTE_HEAD" == "$HEAD" ]] || fail "HEAD is not pushed to origin on branch $BRANCH; push it before publishing"
fi

if (( TAG_ONLY )); then
	local_tag="$(git rev-parse --verify --quiet "refs/tags/$TAG" 2>/dev/null || true)"
	if [[ -n "$local_tag" && "$local_tag" != "$HEAD" ]]; then
		fail "tag $TAG points away from HEAD"
	fi
	REMOTE_TAG="$(git ls-remote --tags --refs origin "refs/tags/$TAG" 2>/dev/null)" ||
		fail 'could not check whether the release tag exists on origin'
	REMOTE_TAG="${REMOTE_TAG%%$'\t'*}"
	if [[ -n "$REMOTE_TAG" && "$REMOTE_TAG" != "$HEAD" ]]; then
		fail "tag $TAG points away from HEAD on origin"
	fi
	if [[ -z "$local_tag" ]]; then
		git tag "$TAG" "$HEAD" || fail "could not create tag $TAG"
	fi
	if [[ -z "$REMOTE_TAG" ]]; then
		git push origin "refs/tags/$TAG" || fail "could not push tag $TAG to origin"
	fi
	printf 'Tag ready: %s\n' "$TAG"
	exit 0
fi

if [[ -z "$NOTES_FILE" && -f "$ROOT/dist/RELEASE_NOTES.md" ]]; then
	NOTES_FILE="$ROOT/dist/RELEASE_NOTES.md"
fi
if [[ -n "$NOTES_FILE" ]]; then
	[[ -f "$NOTES_FILE" ]] || fail "release notes file does not exist: $NOTES_FILE"
	NOTES_BODY="$(<"$NOTES_FILE")"
else
	NOTES_BODY=""
fi

resolve_fj() {
	local candidate resolved
	local -a candidates=()
	if [[ -n "${FJ_BIN:-}" ]]; then
		candidates+=("$FJ_BIN")
	fi
	candidates+=("$HOME/.nix-profile/bin/fj")
	resolved="$(command -v fj 2>/dev/null || true)"
	[[ -z "$resolved" ]] || candidates+=("$resolved")
	for candidate in "${candidates[@]}"; do
		if [[ "$candidate" != */* ]]; then
			candidate="$(command -v "$candidate" 2>/dev/null || true)"
		fi
		[[ -x "$candidate" ]] || continue
		if "$candidate" release asset --help >/dev/null 2>&1; then
			FJ="$candidate"
			return 0
		fi
	done
	fail 'Forgejo CLI fj is missing or incompatible; install the canonical Nix forgejo-cli or set FJ_BIN to a compatible binary'
}
resolve_fj

# The API read remains unauthenticated. The response is split from the status
# so a network error and a normal 404 cannot be confused.
API_URL="$FORGEJO_HOST/api/v1/repos/$FORGEJO_REPO/releases/tags/$TAG"
API_RESPONSE="$(curl --fail-with-body --silent --show-error --write-out $'\n%{http_code}' "$API_URL" 2>&1)" || {
	status_line="${API_RESPONSE##*$'\n'}"
	[[ "$status_line" == 404 ]] || fail 'could not query the Forgejo release by tag'
}
API_STATUS="${API_RESPONSE##*$'\n'}"
API_BODY="${API_RESPONSE%$'\n'*}"
RELEASE_EXISTS=0
[[ "$API_STATUS" == 200 ]] && RELEASE_EXISTS=1
[[ "$API_STATUS" == 404 ]] || [[ "$RELEASE_EXISTS" == 1 ]] || fail "Forgejo release lookup returned HTTP $API_STATUS"

# The fj CLI identifies a release by name, not tag. Capture the actual JSON
# name and use it for every asset operation. Release names in this project are
# plain UTF-8; decode the two JSON escapes that can occur in a title.
RELEASE_NAME="$TAG"
if (( RELEASE_EXISTS )); then
	if [[ "$API_BODY" =~ \"name\"[[:space:]]*:[[:space:]]*\"((\\.|[^\"])*)\" ]]; then
		RELEASE_NAME="${BASH_REMATCH[1]}"
	else
		fail 'Forgejo returned a release without a name'
	fi
	RELEASE_NAME="${RELEASE_NAME//\\\"/\"}"
	RELEASE_NAME="${RELEASE_NAME//\\\\/\\}"
	if (( ! REPLACE_ASSET )); then
		fail "release $TAG already exists; rerun with --replace-asset to replace only its zip"
	fi
else
	if (( SKIP_TAG )); then
		local_tag="$(git rev-parse --verify --quiet "refs/tags/$TAG" 2>/dev/null || true)"
		[[ "$local_tag" == "$HEAD" ]] || fail "tag $TAG is not at HEAD; a person at the Mac must run the tag stage first"
	else
		if git rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null; then
			fail "tag $TAG already exists locally"
		fi
		REMOTE_TAG="$(git ls-remote --tags --refs origin "refs/tags/$TAG" 2>/dev/null)" ||
			fail 'could not check whether the release tag exists on origin'
		[[ -z "$REMOTE_TAG" ]] || fail "tag $TAG already exists on origin"
		printf 'Creating local tag %s at HEAD %s\n' "$TAG" "$HEAD"
		git tag "$TAG" "$HEAD" || fail "could not create tag $TAG"
		git push origin "refs/tags/$TAG" || fail "could not push tag $TAG to origin"
	fi
	printf 'Creating Forgejo release %s\n' "$TAG"
	RELEASE_ARGS=("$FJ" -H "$FORGEJO_HOST" release create --repo "$FORGEJO_REPO" "$TAG" --tag "$TAG")
	[[ -z "$NOTES_FILE" ]] || RELEASE_ARGS+=(--body "$NOTES_BODY")
	"${RELEASE_ARGS[@]}" || fail 'could not create the Forgejo release'
fi

ASSET_NAME="Hermternal-$VERSION.zip"
CHECKSUM="$(shasum -a 256 "$ZIP" | cut -d ' ' -f 1)"
if (( REPLACE_ASSET )); then
	# Upload the replacement before deleting the current asset.
	# The temporary asset keeps the published bytes available during replacement.
	if [[ "$API_BODY" == *"\"name\":\"$ASSET_NAME\""* ||
		"$API_BODY" == *"\"name\": \"$ASSET_NAME\""* ]]; then
		TEMP_ASSET_NAME="$ASSET_NAME.pending-$CHECKSUM"
		TEMP_ZIP="$ROOT/dist/$TEMP_ASSET_NAME"
		cp "$ZIP" "$TEMP_ZIP" || fail "could not stage the replacement $ASSET_NAME"
		"$FJ" -H "$FORGEJO_HOST" release asset create --repo "$FORGEJO_REPO" \
			"$RELEASE_NAME" "$TEMP_ZIP" || fail "could not upload the replacement $ASSET_NAME"
		"$FJ" -H "$FORGEJO_HOST" release asset delete --repo "$FORGEJO_REPO" \
			"$RELEASE_NAME" "$ASSET_NAME" || fail "could not delete the old $ASSET_NAME asset"
		"$FJ" -H "$FORGEJO_HOST" release asset create --repo "$FORGEJO_REPO" \
			"$RELEASE_NAME" "$ZIP" || fail "could not publish the replacement $ASSET_NAME"
		"$FJ" -H "$FORGEJO_HOST" release asset delete --repo "$FORGEJO_REPO" \
			"$RELEASE_NAME" "$TEMP_ASSET_NAME" || fail "could not remove the temporary replacement asset"
		rm -f "$TEMP_ZIP"
	else
		printf 'Attaching %s to release %s\n' "$ASSET_NAME" "$RELEASE_NAME"
		"$FJ" -H "$FORGEJO_HOST" release asset create --repo "$FORGEJO_REPO" \
			"$RELEASE_NAME" "$ZIP" || fail "could not upload $ASSET_NAME"
	fi
else
	printf 'Attaching %s to release %s\n' "$ASSET_NAME" "$RELEASE_NAME"
	"$FJ" -H "$FORGEJO_HOST" release asset create --repo "$FORGEJO_REPO" \
		"$RELEASE_NAME" "$ZIP" || fail "could not upload $ASSET_NAME"
fi
RELEASE_URL="$FORGEJO_HOST/$FORGEJO_REPO/releases/tag/$TAG"
printf 'Release URL: %s\n' "$RELEASE_URL"
printf 'SHA-256 (%s): %s\n' "$ASSET_NAME" "$CHECKSUM"
