#!/usr/bin/env bash
set -euo pipefail

# Controlled Mac baseline (2026-08-22): timings/CPU/RSS are report-only because
# a loaded host changes them. Best-of-3 sample: warm query 2.508 ms, cold
# index build 7.711 ms, cache open/store 3.497 ms, projection 0.322 ms;
# user+sys CPU 4.856/6.876/7.253/0.323 ms; peak RSS 19.16/20.17/17.09/20.17
# MiB. Disk baseline is index 180224 and cache 115806 bytes per 1000 rows.
# Release artifact baseline is 4,091,904 bundle bytes (du -sk) and 3,509,848
# Mach-O bytes (stat -f %z). Timings/CPU/RSS remain report-only on loaded hosts.
# The binary gate is deliberately generous at 64 MiB.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BINARY_CEILING_BYTES=$((64 * 1024 * 1024))
mkdir -p "$HOME/tmp"
SCRATCH=$(mktemp -d "$HOME/tmp/hermternal-performance.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT
rsync -a --exclude .git --exclude .build --exclude build --exclude dist "$ROOT/" "$SCRATCH/"

log=$(mktemp "${TMPDIR:-/tmp}/hermternal-performance.XXXXXX")
trap 'rm -f "$log"; rm -rf "$SCRATCH"' EXIT

status=0
(
    cd "$SCRATCH"
    swift test -c release --filter Performance
) >"$log" 2>&1 || status=$?

printf '\nDeterministic performance contracts\n'
printf '%-30s | %-60s\n' 'Contract' 'Measured value (method / gate)' 
printf '%-30s-+-%-60s\n' '------------------------------' '------------------------------------------------------------'
while IFS= read -r line; do
    case "$line" in
        *'PERF|'*)
            value=${line#*PERF|}
            name=${value%%|*}
            metric=${value#*|}
            printf '%-30s | %-60s\n' "$name" "$metric"
            ;;
    esac
done <"$log"
printf '%-30s | %-60s\n' 'warm switch pure work' 'GATED: 16 ms frame, 12 ms pure-work budget, <= 32 deterministic units'
printf '%-30s | %-60s\n' 'cache-hit row parse/measure' 'GATED: counting fake requires parse=0 and measure=0'
printf '%-30s | %-60s\n' 'markdown parse invocation count' 'NOT GATED: no parser invocation counter seam'
printf '%-30s | %-60s\n' 'allocation-free transcript reuse' 'NOT GATED: no allocation counter seam'
printf '%-30s | %-60s\n' 'projection rebuild count' 'NOT GATED: no AppModel projection/open counter seam'
printf '%-30s | %-60s\n' 'actual search row visits' 'NOT GATED: no SQLite trace seam for executed query'
printf '\n'

if (( status != 0 )); then
    cat "$log"
    exit "$status"
fi

artifact_log=$(mktemp "${TMPDIR:-/tmp}/hermternal-artifact.XXXXXX")
artifact_status=0
(
    cd "$SCRATCH"
    CODESIGN_IDENTITY=- CONFIG=release bash Scripts/build-app.sh
) >"$artifact_log" 2>&1 || artifact_status=$?
if (( artifact_status != 0 )); then
    cat "$artifact_log"
    exit "$artifact_status"
fi
app="$SCRATCH/build/Hermternal.app"
bundle_bytes=$(du -sk "$app" | cut -f1)
bundle_bytes=$((bundle_bytes * 1024))
macho_bytes=$(/usr/bin/stat -f %z "$app/Contents/MacOS/Hermternal")
printf '%-30s | %-60s\n' 'release artifact bundle' "${bundle_bytes} bytes (du -sk; report-only)"
printf '%-30s | %-60s\n' 'release Mach-O executable' "${macho_bytes} bytes (stat -f %z; gate <= ${BINARY_CEILING_BYTES})"
rm -f "$artifact_log"

if (( macho_bytes > BINARY_CEILING_BYTES )); then
    printf 'error: release Mach-O exceeds the generous binary-size ceiling\n' >&2
    exit 1
fi
printf 'swift test and release artifact: PASS\n'
