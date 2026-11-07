#!/bin/bash
# Source from the repository root. news_xcodebuild TARGET CONFIGURATION [SETTING=VALUE...] builds one target of
# News.xcodeproj into NEWS_DERIVED_DATA (build/DerivedData of this checkout, so a worktree neither shares nor waits for
# another's build and an unchanged file is never recompiled) and leaves the product under
# "$NEWS_DERIVED_DATA/Build/Products/CONFIGURATION". TARGET_MACOS sets the deployment target (15.0).
NEWS_DERIVED_DATA="${NEWS_DERIVED_DATA:-$PWD/build/DerivedData}"
news_xcodebuild() {
    local target="$1" configuration="$2"
    shift 2
    # -quiet prints warnings and errors only. With it, Xcode 27 also prints "the following command failed with exit
    # code 0 but produced no further output" after a compile that only warned; that line is dropped, the status kept.
    # The unfiltered transcript goes to build/xcodebuild-TARGET.log and is named when the build fails (#577).
    local log="$PWD/build/xcodebuild-$target.log" status
    mkdir -p "$PWD/build"
    xcodebuild -project News.xcodeproj -scheme "$target" -destination "generic/platform=macOS" \
        -configuration "$configuration" -derivedDataPath "$NEWS_DERIVED_DATA" -quiet \
        MACOSX_DEPLOYMENT_TARGET="${TARGET_MACOS:-15.0}" "$@" build 2>&1 | tee "$log" |
        sed '/^error: the following command failed with exit code 0 but produced no further output$/d'
    local statuses=("${PIPESTATUS[@]}")
    status="${statuses[0]}"
    if [[ "${statuses[1]}" != 0 ]]; then
        echo "warning: could not write the transcript $log" >&2
        if [[ "$status" != 0 ]]; then echo "xcodebuild failed ($status)" >&2; fi
    elif [[ "$status" != 0 ]]; then
        echo "xcodebuild failed ($status); full transcript: $log" >&2
    fi
    return "$status"
}
