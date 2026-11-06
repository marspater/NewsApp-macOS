#!/bin/bash
# The arm64 verification build (every CI provider and .github/workflows/release.yml): build.sh with whole-module
# optimization and never Sentry, signed ad hoc with the hardened runtime like the development build.
set -e

echo "=================================================="
echo "🚀 Building arm64 Verification for News"
echo "=================================================="
NEWS_SENTRY_DISABLED=1 NEWS_WHOLE_MODULE=1 ./build.sh
lipo News.app/Contents/MacOS/News -verify_arch arm64

echo "✅ Verifying code signature..."
codesign --verify --deep --strict --verbose=2 News.app
codesign -d --entitlements - News.app

echo ""
echo "🎉 arm64 Verification Build complete at News.app!"
