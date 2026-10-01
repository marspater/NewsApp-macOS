#!/bin/bash
set -e

APP_NAME="News"
APP_DIR="${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
BUILD_TMP=$(mktemp -d "${TMPDIR:-/tmp}/news-release.XXXXXX")

TARGET_MACOS="${TARGET_MACOS:-15.0}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/news-module-cache}"
export SWIFT_MODULECACHE_PATH="$CLANG_MODULE_CACHE_PATH"


echo "=================================================="
echo "🚀 Building arm64 Verification for ${APP_NAME} (macOS ${TARGET_MACOS})"
echo "=================================================="

rm -rf "${APP_DIR}" "${BUILD_TMP}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}" "${BUILD_TMP}" Assets

cp container-migration.plist PrivacyInfo.xcprivacy "${RESOURCES_DIR}/"

# Compile the editable Icon Composer source, including legacy macOS fallback.
xcrun actool "$(pwd)/Assets/AppIcon.icon" --compile "$(pwd)/${RESOURCES_DIR}" \
    --platform macosx --minimum-deployment-target "${TARGET_MACOS}" \
    --app-icon AppIcon --output-partial-info-plist "$(pwd)/${CONTENTS_DIR}/IconInfo.plist"

SWIFT_SOURCES=(
    Sources/Services/DateParser.swift
    Sources/Models/FeedError.swift
    Sources/Models/FeedFetchState.swift
    Sources/Models/FeedCatalog.swift
    Sources/Services/IPAddressValidator.swift
    Sources/Models/ArticleIdentity.swift
    Sources/Models/EventOverview.swift
    Sources/Storage/DatabaseEngine.swift
    Sources/Storage/MigrationCoordinator.swift
    Sources/Storage/ArticleStore.swift
    Sources/Intelligence/ArticleIntelligence.swift
    Sources/Intelligence/OverviewPassageSelector.swift
    Sources/Intelligence/PromptDefense.swift
    Sources/Intelligence/ModelAvailability.swift
    Sources/Intelligence/PassageFactExtractor.swift
    Sources/Intelligence/OverviewComposer.swift
    Sources/Intelligence/ContentExtractionPipeline.swift
    Sources/Intelligence/EnrichmentQueue.swift
    Sources/Services/NetworkBoundaryProxy.swift
    Sources/Views/WebPreviewPolicy.swift
    Sources/Services/SecureHTTPClient.swift
    Sources/App/AppSettings.swift
    Sources/Services/FeedXMLParser.swift
    Sources/Intelligence/WebContentExtractor.swift
    Sources/Coordinators/NotificationService.swift
    Sources/Services/FeedFetcher.swift
    Sources/Services/JSONFeedParser.swift
    Sources/Storage/ReadManager.swift
    Sources/App/ThemeManager.swift
    Sources/Models/FeedArticle.swift
    Sources/Storage/CacheManager.swift
    Sources/Coordinators/FeedManager.swift
    Sources/App/AppContainer.swift
    Sources/Views/DesignSystem.swift
    Sources/Views/GlassSystem.swift
    Sources/Views/SidebarView.swift
    Sources/Views/ArticleCardView.swift
    Sources/Views/ArticleListView.swift
    Sources/Views/ArticleDetailView.swift
    Sources/Views/MainView.swift
    Sources/Views/SettingsView.swift
    Sources/Views/FeedCatalogView.swift
    Sources/Views/FeedHealthLine.swift
    Sources/Storage/SavedStoriesManager.swift
    Sources/Services/OPMLManager.swift
    Sources/Views/ArticleWebView.swift
    Sources/Coordinators/RefreshCoordinator.swift
    Sources/App/NewsSignposts.swift
    Sources/App/UpdateChecker.swift
    Sources/App/NewsApp.swift
)

echo "⚙️ Compiling arm64 slice..."
swiftc -swift-version 6 -O -whole-module-optimization -parse-as-library \
    -target arm64-apple-macos${TARGET_MACOS} \
    "${SWIFT_SOURCES[@]}" \
    -o "${BUILD_TMP}/News_arm64"

echo "📋 Verifying arm64 binary..."
cp "${BUILD_TMP}/News_arm64" "${MACOS_DIR}/${APP_NAME}"
lipo "${MACOS_DIR}/${APP_NAME}" -verify_arch arm64

# Create Info.plist
cat > "${CONTENTS_DIR}/Info.plist" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>News</string>
    <key>CFBundleIdentifier</key>
    <string>com.marspater.news</string>
    <key>CFBundleName</key>
    <string>News</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>2.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>${TARGET_MACOS}</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST_EOF

# Code signing with Hardened Runtime
echo "🔐 Signing binary with Hardened Runtime..."
find "${APP_DIR}" -name ".DS_Store" -delete

SIGN_IDENTITY="-"
SIGN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/news-sign.XXXXXX")
TEMP_APP="${SIGN_TMP}/${APP_DIR}"
cp -R "${APP_DIR}" "${TEMP_APP}"
find "${TEMP_APP}" -exec xattr -c {} \; 2>/dev/null || true
find "${TEMP_APP}" -exec xattr -d com.apple.FinderInfo {} \; 2>/dev/null || true

codesign --force --deep --options runtime \
    --entitlements News.entitlements \
    --sign "${SIGN_IDENTITY}" \
    "${TEMP_APP}"

rm -rf "${APP_DIR}"
cp -R "${TEMP_APP}" "${APP_DIR}"
rm -rf "${SIGN_TMP}" "${BUILD_TMP}"

echo "✅ Verifying code signature..."
codesign --verify --deep --strict --verbose=2 "${APP_DIR}"
codesign -d --entitlements - "${APP_DIR}"

echo ""
echo "🎉 arm64 Verification Build complete at ${APP_DIR}!"
