#!/bin/bash
set -e

APP_NAME="News"
APP_DIR="${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
BUILD_TMP="/tmp/news_release_build"

HOST_MACOS_VER=$(sw_vers -productVersion 2>/dev/null | cut -d. -f1,2 || echo "27.0")
TARGET_MACOS="${TARGET_MACOS:-$HOST_MACOS_VER}"

echo "=================================================="
echo "🚀 Building Universal 2 Release for ${APP_NAME} (macOS ${TARGET_MACOS})"
echo "=================================================="

rm -rf "${APP_DIR}" "${BUILD_TMP}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}" "${BUILD_TMP}" Assets

# Icon Generation
ICON_SRC="Assets/AppIcon_alpha.png"
if [ ! -f "$ICON_SRC" ]; then
    ICON_SRC="Assets/AppIcon.png"
fi

if [ -f "$ICON_SRC" ]; then
    echo "📦 Generating app icon from $ICON_SRC..."
    rm -rf Assets/AppIcon.iconset
    mkdir -p Assets/AppIcon.iconset
    sips -z 16 16     "$ICON_SRC" --out Assets/AppIcon.iconset/icon_16x16.png     2>/dev/null
    sips -z 32 32     "$ICON_SRC" --out Assets/AppIcon.iconset/icon_16x16@2x.png  2>/dev/null
    sips -z 32 32     "$ICON_SRC" --out Assets/AppIcon.iconset/icon_32x32.png     2>/dev/null
    sips -z 64 64     "$ICON_SRC" --out Assets/AppIcon.iconset/icon_32x32@2x.png  2>/dev/null
    sips -z 128 128   "$ICON_SRC" --out Assets/AppIcon.iconset/icon_128x128.png   2>/dev/null
    sips -z 256 256   "$ICON_SRC" --out Assets/AppIcon.iconset/icon_128x128@2x.png 2>/dev/null
    sips -z 256 256   "$ICON_SRC" --out Assets/AppIcon.iconset/icon_256x256.png   2>/dev/null
    sips -z 512 512   "$ICON_SRC" --out Assets/AppIcon.iconset/icon_256x256@2x.png 2>/dev/null
    sips -z 512 512   "$ICON_SRC" --out Assets/AppIcon.iconset/icon_512x512.png   2>/dev/null
    sips -z 1024 1024 "$ICON_SRC" --out Assets/AppIcon.iconset/icon_512x512@2x.png 2>/dev/null
    xattr -cr Assets/AppIcon.iconset 2>/dev/null || true
    iconutil -c icns Assets/AppIcon.iconset -o Assets/AppIcon.icns 2>/dev/null || true
    rm -rf Assets/AppIcon.iconset
fi

if [ -f "Assets/AppIcon.icns" ]; then
    cp Assets/AppIcon.icns "${RESOURCES_DIR}/AppIcon.icns"
fi

SWIFT_SOURCES=(
    DateParser.swift
    FeedError.swift
    IPAddressValidator.swift
    ArticleIdentity.swift
    DatabaseEngine.swift
    MigrationCoordinator.swift
    ArticleStore.swift
    ArticleIntelligence.swift
    ContentExtractionPipeline.swift
    EnrichmentQueue.swift
    SecureHTTPClient.swift
    AppSettings.swift
    FeedXMLParser.swift
    WebContentExtractor.swift
    NotificationService.swift
    FeedFetcher.swift
    JSONFeedParser.swift
    ReadManager.swift
    ThemeManager.swift
    FeedArticle.swift
    CacheManager.swift
    AIManager.swift
    FeedManager.swift
    AppContainer.swift
    DesignSystem.swift
    GlassSystem.swift
    SidebarView.swift
    ArticleCardView.swift
    ArticleListView.swift
    ArticleDetailView.swift
    MainView.swift
    SettingsView.swift
    SavedStoriesManager.swift
    OPMLManager.swift
    ArticleWebView.swift
    RefreshCoordinator.swift
    NewsSignposts.swift
    UpdateChecker.swift
    NewsApp.swift
)

echo "⚙️ Compiling arm64 slice..."
swiftc -O -whole-module-optimization -parse-as-library \
    -target arm64-apple-macos${TARGET_MACOS} \
    "${SWIFT_SOURCES[@]}" \
    -o "${BUILD_TMP}/News_arm64"

echo "⚙️ Compiling x86_64 slice..."
swiftc -O -whole-module-optimization -parse-as-library \
    -target x86_64-apple-macos${TARGET_MACOS} \
    "${SWIFT_SOURCES[@]}" \
    -o "${BUILD_TMP}/News_x86_64"

echo "🔗 Creating Universal 2 binary with lipo..."
lipo -create "${BUILD_TMP}/News_arm64" "${BUILD_TMP}/News_x86_64" -output "${MACOS_DIR}/${APP_NAME}"

echo "📋 Binary architectures:"
lipo -info "${MACOS_DIR}/${APP_NAME}"

# Create Info.plist
cat > "${CONTENTS_DIR}/Info.plist" << 'PLIST_EOF'
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
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>2.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
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

SIGN_IDENTITY="${DEVELOPER_ID:--}"
TEMP_APP="/tmp/${APP_DIR}"
rm -rf "${TEMP_APP}"
cp -R "${APP_DIR}" "${TEMP_APP}"
find "${TEMP_APP}" -exec xattr -c {} \; 2>/dev/null || true
find "${TEMP_APP}" -exec xattr -d com.apple.FinderInfo {} \; 2>/dev/null || true

codesign --force --deep --options runtime \
    --entitlements News.entitlements \
    --sign "${SIGN_IDENTITY}" \
    "${TEMP_APP}"

rm -rf "${APP_DIR}"
cp -R "${TEMP_APP}" "${APP_DIR}"
rm -rf "${TEMP_APP}" "${BUILD_TMP}"

echo "✅ Verifying code signature..."
codesign --verify --deep --strict --verbose=2 "${APP_DIR}"
codesign -d --entitlements :- "${APP_DIR}"

echo ""
echo "🎉 Universal 2 Release Build complete at ${APP_DIR}!"
