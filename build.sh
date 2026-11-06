#!/bin/bash
# Builds News.app from News.xcodeproj and signs it ad hoc with the hardened runtime and News.entitlements. The build
# is incremental: build/DerivedData keeps this checkout's last build, so only changed files recompile (#1020).
#   NEWS_BUNDLE_ID          bundle identifier (com.marspater.news); isolated builds get their own
#   NEWS_APP_DIR            where the bundle is written (News.app, replaced; NewsHarness.app for a harness)
#   NEWS_HARNESS            Tests/Harness/<Entry>.swift (space-separated for several): builds the NewsHarness app,
#                           every file under Sources/ except the app's entry point plus these and
#                           Tests/TestDefaults.swift
#   NEWS_OMIT_RESOURCES     resource file names left out of the bundle (build_and_run.sh: container-migration.plist)
#   NEWS_WHOLE_MODULE=1     whole-module optimization (build_release.sh); the default is -O per file, incremental
#   SENTRY_DSN, .sentry-dsn links Sentry crash reporting (script/sentry_dev.sh); NEWS_SENTRY_DISABLED=1 forces it off
set -e

source script/version.sh
source script/xcode_build.sh
source script/sentry_dev.sh

TARGET=News
APP_DIR="${NEWS_APP_DIR:-News.app}"
SETTINGS=(MARKETING_VERSION="$NEWS_VERSION" CURRENT_PROJECT_VERSION="$NEWS_BUILD"
    PRODUCT_BUNDLE_IDENTIFIER="${NEWS_BUNDLE_ID:-com.marspater.news}" "${NEWS_SENTRY_SETTINGS[@]}")
if [[ -n "${NEWS_HARNESS:-}" ]]; then
    TARGET=NewsHarness
    APP_DIR="${NEWS_APP_DIR:-NewsHarness.app}"
    SETTINGS+=(NEWS_HARNESS="$NEWS_HARNESS")
fi
if [[ "${NEWS_WHOLE_MODULE:-0}" == 1 ]]; then SETTINGS+=(SWIFT_COMPILATION_MODE=wholemodule); fi
# The project keeps Tests/* out of the harness app (INCLUDED_SOURCE_FILE_NAMES adds the entry back), so an override
# restates it.
if [[ -n "${NEWS_OMIT_RESOURCES:-}" ]]; then SETTINGS+=(EXCLUDED_SOURCE_FILE_NAMES="Tests/* Tests/Harness/* $NEWS_OMIT_RESOURCES"); fi

echo "Building ${TARGET} ${NEWS_VERSION} (${NEWS_BUILD}) for macOS ${TARGET_MACOS:-15.0} (arm64)..."
news_xcodebuild "$TARGET" Release "${SETTINGS[@]}"

rm -rf "$APP_DIR"
ditto "$NEWS_DERIVED_DATA/Build/Products/Release/$TARGET.app" "$APP_DIR"
if [[ -n "$SENTRY_DSN" ]]; then
    plutil -insert SentryDSN -string "$SENTRY_DSN" "$APP_DIR/Contents/Info.plist"
    codesign --force --options runtime --entitlements News.entitlements --sign - "$APP_DIR"
fi
codesign --verify --deep --strict "$APP_DIR"
echo "Build complete. App is ready at ${APP_DIR}!"
