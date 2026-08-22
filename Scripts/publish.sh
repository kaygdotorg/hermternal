#!/bin/bash
# Create the Forgejo release for the already-built, notarized archive.
#
# Run Scripts/release.sh on the Mac first. Publishing is deliberately separate
# because it only needs the checked-in commit, the zip, and network access.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FORGEJO_HOST="${FORGEJO_HOST:-https://git.kayg.org}"
FORGEJO_HOST="${FORGEJO_HOST%/}"
FORGEJO_REPO="kayg/hermternal-apple"

# These are emergency-only escape hatches. Keep the checks enabled for normal
# releases: a dirty tree or an unpushed commit makes the binary unreproducible.
ALLOW_DIRTY="${PUBLISH_ALLOW_DIRTY:-0}"
ALLOW_UNPUSHED="${PUBLISH_ALLOW_UNPUSHED:-0}"

usage() {
	printf 'Usage: %s [--notes-file PATH]\n' "${BASH_SOURCE[0]}"
	printf '\n'
	printf 'Create the v<version> Forgejo release and attach its zip.\n'
	printf 'If --notes-file is omitted, dist/RELEASE_NOTES.md is used when present.\n'
	printf '\n'
	printf 'Emergency overrides: PUBLISH_ALLOW_DIRTY=1 and/or PUBLISH_ALLOW_UNPUSHED=1.\n'
}

die() {
	printf 'error: %s\n' "$1" >&2
	exit 1
}

NOTES_FILE=''
while (($# > 0)); do
	case "$1" in
		--notes-file)
			(($# >= 2)) || die '--notes-file requires a path'
			NOTES_FILE="$2"
			shift 2
			;;
		--notes-file=*)
			NOTES_FILE="${1#*=}"
			[[ -n "$NOTES_FILE" ]] || die '--notes-file requires a path'
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			die "unknown argument: $1"
			;;
	esac
done

if [[ "$ALLOW_DIRTY" != 1 ]]; then
	[[ -z "$(git status --porcelain=v1)" ]] ||
		die 'working tree is dirty; commit or stash changes, or set PUBLISH_ALLOW_DIRTY=1 for an emergency release'
fi

# Check for an archive before invoking the macOS-only PlistBuddy. This keeps
# the missing-artifact failure useful on another machine as well as on the Mac.
shopt -s nullglob
artifacts=("$ROOT"/dist/Hermternal-*.zip)
shopt -u nullglob
((${#artifacts[@]} > 0)) ||
	die "release artifact is missing; run Scripts/release.sh first (expected dist/Hermternal-<version>.zip)"

VERSION="$(
	/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
		Resources/Info.plist
)"
[[ -n "$VERSION" ]] || die 'could not read CFBundleShortVersionString from Resources/Info.plist'

ZIP="$ROOT/dist/Hermternal-$VERSION.zip"
[[ -f "$ZIP" ]] ||
	die "release artifact is missing: dist/Hermternal-$VERSION.zip; run Scripts/release.sh first"

HEAD="$(git rev-parse HEAD)"
BRANCH="$(git symbolic-ref --quiet --short HEAD || true)"
if [[ "$ALLOW_UNPUSHED" != 1 ]]; then
	[[ -n "$BRANCH" ]] ||
		die 'HEAD is detached and cannot be verified as pushed to origin; set PUBLISH_ALLOW_UNPUSHED=1 to override'

	if ! REMOTE_HEAD="$(git ls-remote --heads origin "refs/heads/$BRANCH" 2>/dev/null)"; then
		die "could not verify whether HEAD is pushed to origin; check the origin remote, or set PUBLISH_ALLOW_UNPUSHED=1 for an emergency release"
	fi
	REMOTE_HEAD="${REMOTE_HEAD%%$'\t'*}"
	[[ "$REMOTE_HEAD" == "$HEAD" ]] ||
		die "HEAD is not pushed to origin on branch $BRANCH; push it first, or set PUBLISH_ALLOW_UNPUSHED=1 for an emergency release"
fi

if [[ -z "$NOTES_FILE" && -f "$ROOT/dist/RELEASE_NOTES.md" ]]; then
	NOTES_FILE="$ROOT/dist/RELEASE_NOTES.md"
fi
if [[ -n "$NOTES_FILE" ]]; then
	[[ -f "$NOTES_FILE" ]] || die "release notes file does not exist: $NOTES_FILE"
	NOTES_BODY="$(<"$NOTES_FILE")"
else
	NOTES_BODY=''
fi
TAG="v$VERSION"

if git rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null; then
	die "tag $TAG already exists locally; refusing to recreate it"
fi

if ! REMOTE_TAG="$(git ls-remote --tags --refs origin "refs/tags/$TAG" 2>/dev/null)"; then
	die "could not check whether tag $TAG exists on origin; check the origin remote before publishing"
fi
if [[ -n "$REMOTE_TAG" ]]; then
	die "tag $TAG already exists on origin; refusing to recreate it"
fi

printf 'Creating local tag %s at HEAD %s\n' "$TAG" "$HEAD"
git tag "$TAG" "$HEAD"

printf 'Pushing tag %s to origin\n' "$TAG"
git push origin "refs/tags/$TAG" ||
	die "could not push tag $TAG to origin; it may already exist remotely"

printf 'Creating Forgejo release %s\n' "$TAG"
RELEASE_ARGS=(
	fj -H "$FORGEJO_HOST" release create
	--repo "$FORGEJO_REPO"
	"$TAG"
	--tag "$TAG"
)
if [[ -n "$NOTES_FILE" ]]; then
	RELEASE_ARGS+=(--body "$NOTES_BODY")
fi
"${RELEASE_ARGS[@]}"

printf 'Attaching %s\n' "$ZIP"
fj -H "$FORGEJO_HOST" release asset create \
	--repo "$FORGEJO_REPO" "$TAG" "$ZIP"

RELEASE_URL="$FORGEJO_HOST/$FORGEJO_REPO/releases/tag/$TAG"
CHECKSUM="$(shasum -a 256 "$ZIP" | cut -d ' ' -f 1)"
printf '\nRelease URL: %s\n' "$RELEASE_URL"
printf 'SHA-256 (%s): %s\n' "$(basename "$ZIP")" "$CHECKSUM"
