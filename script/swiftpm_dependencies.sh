#!/bin/bash
# Source from the repository root before invoking swiftc. SwiftPM owns dependency resolution and compilation.
NEWS_DEPENDENCY_ARCH="${NEWS_DEPENDENCY_ARCH:-$(uname -m)}"
swift build --force-resolved-versions --configuration release --arch "$NEWS_DEPENDENCY_ARCH" \
    --product NewsParsingDependencies >&2
NEWS_DEPENDENCY_BIN=$(swift build --force-resolved-versions --configuration release \
    --arch "$NEWS_DEPENDENCY_ARCH" --show-bin-path)
# Caller scripts consume this array after sourcing; Bash arrays cannot be exported to child processes.
# shellcheck disable=SC2034
NEWS_DEPENDENCY_FLAGS=(-I "$NEWS_DEPENDENCY_BIN" -I "$NEWS_DEPENDENCY_BIN/Modules" "$NEWS_DEPENDENCY_BIN/libNewsParsingDependencies.a")
