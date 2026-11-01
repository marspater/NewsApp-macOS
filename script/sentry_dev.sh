#!/bin/bash
# Caller scripts consume NEWS_SENTRY_FLAGS after sourcing.
# shellcheck disable=SC2034
# Source from the repository root before invoking swiftc in build.sh (dev builds only).
# Links Sentry crash reporting when a DSN is set in SENTRY_DSN or the untracked .sentry-dsn file;
# otherwise the build is identical to one without Sentry. NEWS_SENTRY_DISABLED=1 forces it off.
# build_release.sh never sources this.
SENTRY_VERSION=9.32.0
XCFRAMEWORK_SHA256=ae8864b653ede36cea934552348941b92f6dcd5d7e94c3227d8a9bb168256bcc
if [[ "${NEWS_SENTRY_DISABLED:-0}" == 1 ]]; then
    SENTRY_DSN=""
else
    SENTRY_DSN="${SENTRY_DSN:-$(cat .sentry-dsn 2>/dev/null || true)}"
fi
NEWS_SENTRY_FLAGS=()
if [[ -n "$SENTRY_DSN" ]]; then
    SENTRY_DIR="build/sentry-${SENTRY_VERSION}"
    if [[ ! -d "${SENTRY_DIR}/Sentry.xcframework" ]]; then
        mkdir -p "$SENTRY_DIR"
        curl -fsSL --proto "=https" --proto-redir "=https" --tlsv1.2 -o "${SENTRY_DIR}/Sentry.xcframework.zip" \
            "https://github.com/getsentry/sentry-cocoa/releases/download/${SENTRY_VERSION}/Sentry.xcframework.zip"
        echo "${XCFRAMEWORK_SHA256}  ${SENTRY_DIR}/Sentry.xcframework.zip" | shasum -a 256 -c - >&2
        ditto -x -k "${SENTRY_DIR}/Sentry.xcframework.zip" "$SENTRY_DIR"
        rm "${SENTRY_DIR}/Sentry.xcframework.zip"
    fi
    SENTRY_SLICE=$(find "${SENTRY_DIR}/Sentry.xcframework" -maxdepth 1 -type d -name 'macos-*' | head -1)
    NEWS_SENTRY_FLAGS=(-D NEWS_SENTRY -F "$SENTRY_SLICE" -framework Sentry -lc++ -lz)
    echo "Linking Sentry ${SENTRY_VERSION} (dev build)" >&2
fi
