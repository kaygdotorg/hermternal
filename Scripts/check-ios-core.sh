#!/bin/bash
# Type-check every HermternalCore source against the iOS Simulator SDK.
#
# This intentionally invokes swiftc directly instead of `swift build`: the
# package's Hermternal executable target is macOS-only (AppKit/SwiftUI), while
# this gate must prove the Foundation/domain Core target is iOS-portable.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK_NAME="iphonesimulator"
export LC_ALL=C

XCRUN=(xcrun --sdk "$SDK_NAME")
SDK_PATH="$("${XCRUN[@]}" --show-sdk-path)"
SDK_VERSION="$("${XCRUN[@]}" --show-sdk-version)"
TARGET="arm64-apple-ios${SDK_VERSION}-simulator"

SOURCES=()
while IFS= read -r source; do
	SOURCES+=("$source")
done < <(find "$ROOT/Sources/HermternalCore" -type f -name '*.swift' -print | sort)
if ((${#SOURCES[@]} == 0)); then
	echo "error: no HermternalCore Swift sources found" >&2
	exit 1
fi

echo "Type-checking ${#SOURCES[@]} HermternalCore sources for iOS Simulator ($TARGET)"
echo "SDK: $SDK_PATH"
exec "${XCRUN[@]}" swiftc \
	-typecheck \
	-parse-as-library \
	-module-name HermternalCore \
	-swift-version 6 \
	-sdk "$SDK_PATH" \
	-target "$TARGET" \
	"${SOURCES[@]}"
