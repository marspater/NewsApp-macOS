#!/bin/bash
# Measures build times per docs/audits/2026-11-07-build-measurement-protocol.md: cold ./build.sh (Release),
# incremental ./build.sh after touching one Sources/Models file and one Sources/Views file, and a cold NewsTests
# build-for-testing (Debug), three runs each, one at a time, in a scratch DerivedData (the app bundle goes there too). Builds only; nothing is launched. Run from the repository root, only
# when no other build runs on this Mac.
#   NEWS_MEASURE_RESULTS  results file (build/measure-results.txt); each run is appended as it finishes
set -euo pipefail

LOCK="${TMPDIR:-/tmp}/news-measure.lock"   # outside the checkout, so it spans every worktree
RESULTS="${NEWS_MEASURE_RESULTS:-build/measure-results.txt}"
mkdir -p build
if pgrep -f 'xcodebuild|swift-build|swiftc' >/dev/null; then echo "Another build is running; not measuring." >&2; exit 1; fi
mkdir "$LOCK" 2>/dev/null || { echo "$LOCK exists: another measurement is running." >&2; exit 1; }
export NEWS_DERIVED_DATA
NEWS_DERIVED_DATA="$(mktemp -d)/DerivedData"
trap 'rm -rf "$LOCK" "$(dirname "$NEWS_DERIVED_DATA")"' EXIT

XCODE="$(xcodebuild -version | tr '\n' ' ')"
MODELS_FILE=Sources/Models/FeedError.swift
VIEWS_FILE=Sources/Views/List/ArticleCardView.swift

app() { NEWS_APP_DIR="$(dirname "$NEWS_DERIVED_DATA")/News.app" NEWS_SENTRY_DISABLED=1 ./build.sh; }
tests() {
    xcodebuild build-for-testing -project News.xcodeproj -scheme News -destination 'platform=macOS' \
        -derivedDataPath "$NEWS_DERIVED_DATA" -only-testing:NewsTests -quiet
}
# measure CASE COMMAND...: times one build and appends "time case seconds commit xcode load" to the results file.
measure() {
    local name="$1" load start
    shift
    load="$(sysctl -n vm.loadavg)"
    start=$(date +%s)
    "$@" || { echo "$name failed; the xcodebuild output above has the reason" >&2; exit 1; }
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%FT%T)" "$name" "$(($(date +%s) - start))" \
        "$(git rev-parse --short HEAD)" "$XCODE" "$load" | tee -a "$RESULTS"
}

for run in 1 2 3; do
    rm -rf "$NEWS_DERIVED_DATA"
    measure cold_app app
    touch "$MODELS_FILE"
    measure incremental_models app
    touch "$VIEWS_FILE"
    measure incremental_views app
    rm -rf "$NEWS_DERIVED_DATA"
    measure newstests_build tests
done

echo "Median of three (seconds), from $RESULTS:"
for name in cold_app incremental_models incremental_views newstests_build; do
    printf '%s\t' "$name"
    awk -F'\t' -v n="$name" '$2 == n { print $3 }' "$RESULTS" | tail -3 | sort -n | sed -n 2p
done
