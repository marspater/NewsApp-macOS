#!/bin/bash
# Builds News.app from News.xcodeproj and signs it ad hoc with the hardened runtime and News.entitlements. The build
# is incremental: build/DerivedData keeps this checkout's last build, so only changed files recompile (#1020).
#   NEWS_BUNDLE_ID          bundle identifier (com.marspater.news); isolated builds get their own
#   NEWS_APP_DIR            where the bundle is written (News.app, replaced; NewsHarness.app for a harness)
#   NEWS_HARNESS            Tests/Harness/<Entry>.swift (space-separated for several): builds the NewsHarness app,
#                           every file under Sources/ except the app's entry point plus these and
#                           Tests/TestDefaults.swift
#   NEWS_HARNESS_SANDBOX=1  signs the harness app with News.entitlements and the hardened runtime, as the app is; by
#                           default a harness is unsandboxed and can write its evidence where its script says
#   NEWS_OMIT_RESOURCES     resource file names left out of the bundle (build_and_run.sh: container-migration.plist)
#   NEWS_CONFIGURATION      Release (default); Debug: a harness that checks behaviour, not speed, compiles faster
#                           unoptimized (CI's publisher-excerpt step, #577); Profile: optimized like Release, always
#                           com.marspater.news.dev and without container-migration.plist (profile_signposts.sh)
#   NEWS_WHOLE_MODULE=1     whole-module optimization (build_release.sh); the default is -O per file, incremental
#   SENTRY_DSN, .sentry-dsn links Sentry crash reporting (script/sentry_dev.sh); NEWS_SENTRY_DISABLED=1 forces it off
set -e

source script/version.sh
source script/xcode_build.sh
source script/sentry_dev.sh

TARGET=News
CONFIGURATION="${NEWS_CONFIGURATION:-Release}"
APP_DIR="${NEWS_APP_DIR:-News.app}"
BUNDLE_ID="${NEWS_BUNDLE_ID:-com.marspater.news}"
# Profile is the optimized measurement build: it keeps the development identifier, so it never opens the real library.
if [[ "$CONFIGURATION" == Profile ]]; then
    if [[ -n "${NEWS_BUNDLE_ID:-}" && "$NEWS_BUNDLE_ID" != com.marspater.news.dev ]]; then
        echo "❌ NEWS_CONFIGURATION=Profile builds only com.marspater.news.dev, not $NEWS_BUNDLE_ID" >&2
        exit 1
    fi
    BUNDLE_ID=com.marspater.news.dev
fi
SETTINGS=(MARKETING_VERSION="$NEWS_VERSION" CURRENT_PROJECT_VERSION="$NEWS_BUILD"
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" "${NEWS_SENTRY_SETTINGS[@]}")
if [[ -n "${NEWS_HARNESS:-}" ]]; then
    TARGET=NewsHarness
    APP_DIR="${NEWS_APP_DIR:-NewsHarness.app}"
    SETTINGS+=(NEWS_HARNESS="$NEWS_HARNESS")
    if [[ "${NEWS_HARNESS_SANDBOX:-0}" == 1 ]]; then
        SETTINGS+=(CODE_SIGN_ENTITLEMENTS=News.entitlements ENABLE_HARDENED_RUNTIME=YES)
    fi
fi
if [[ "${NEWS_WHOLE_MODULE:-0}" == 1 ]]; then SETTINGS+=(SWIFT_COMPILATION_MODE=wholemodule); fi
# The project keeps Tests/* (and, for a harness, the migration plist) out of the bundle, so an override restates it.
if [[ -n "${NEWS_OMIT_RESOURCES:-}" ]]; then
    # The override replaces the configuration's list, so keep the plist out wherever the configuration does.
    MIGRATION=""
    if [[ -n "${NEWS_HARNESS:-}" || "$CONFIGURATION" != Release ]]; then MIGRATION=container-migration.plist; fi
    SETTINGS+=(EXCLUDED_SOURCE_FILE_NAMES="Tests/* Tests/Harness/* $MIGRATION $NEWS_OMIT_RESOURCES")
fi

echo "Building ${TARGET} ${NEWS_VERSION} (${NEWS_BUILD}) for macOS ${TARGET_MACOS:-15.0} (arm64)..."
news_xcodebuild "$TARGET" "$CONFIGURATION" "${SETTINGS[@]}"

rm -rf "$APP_DIR"
ditto "$NEWS_DERIVED_DATA/Build/Products/$CONFIGURATION/$TARGET.app" "$APP_DIR"
if [[ -n "$SENTRY_DSN" ]]; then
    plutil -insert SentryDSN -string "$SENTRY_DSN" "$APP_DIR/Contents/Info.plist"
    codesign --force --options runtime --entitlements News.entitlements --sign - "$APP_DIR"
fi
codesign --verify --deep --strict "$APP_DIR"
echo "Build complete. App is ready at ${APP_DIR}!"
