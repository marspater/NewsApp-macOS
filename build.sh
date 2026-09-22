#!/bin/bash
set -e

APP_NAME="News"
APP_DIR="${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

# Target macOS configuration (defaults to host macOS version or TARGET_MACOS env var)
HOST_MACOS_VER=$(sw_vers -productVersion 2>/dev/null | cut -d. -f1,2 || echo "27.0")
TARGET_MACOS="${TARGET_MACOS:-$HOST_MACOS_VER}"

echo "Building ${APP_NAME} v2.0 for macOS ${TARGET_MACOS} ($(uname -m))..."

# Clean old build
rm -rf "${APP_DIR}"

# Create directories
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"
mkdir -p Assets

# --- Icon Generation ---
# Use the RGBA PNG (converted from the JPEG-encoded original)
ICON_SRC="Assets/AppIcon_alpha.png"
if [ ! -f "$ICON_SRC" ]; then
    echo "Warning: $ICON_SRC not found, attempting conversion..."
    # Fallback: compile converter and run
    if [ -f "/tmp/convert_icon" ]; then
        /tmp/convert_icon Assets/AppIcon.png Assets/AppIcon_alpha.png
    else
        ICON_SRC="Assets/AppIcon.png"
    fi
fi

if [ -f "$ICON_SRC" ]; then
    echo "Generating app icon from $ICON_SRC..."

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

    # Remove extended attributes from iconset files
    xattr -cr Assets/AppIcon.iconset 2>/dev/null || true

    iconutil -c icns Assets/AppIcon.iconset -o Assets/AppIcon.icns 2>/dev/null && \
        echo "AppIcon.icns generated successfully." || \
        echo "Warning: iconutil failed, icon may not display."

    # Clean up iconset intermediates
    rm -rf Assets/AppIcon.iconset
fi

# Copy AppIcon to Resources
if [ -f "Assets/AppIcon.icns" ]; then
    cp Assets/AppIcon.icns "${RESOURCES_DIR}/AppIcon.icns"
fi

# Compile Swift files (exclude any standalone scripts)
swiftc -O -parse-as-library -target $(uname -m)-apple-macos${TARGET_MACOS} \
    Sources/Services/DateParser.swift \
    Sources/Models/FeedError.swift \
    Sources/Services/IPAddressValidator.swift \
    Sources/Models/ArticleIdentity.swift \
    Sources/Storage/DatabaseEngine.swift \
    Sources/Storage/MigrationCoordinator.swift \
    Sources/Storage/ArticleStore.swift \
    Sources/Intelligence/ArticleIntelligence.swift \
    Sources/Intelligence/ContentExtractionPipeline.swift \
    Sources/Intelligence/EnrichmentQueue.swift \
    Sources/Services/SecureHTTPClient.swift \
    Sources/App/AppSettings.swift \
    Sources/Services/FeedXMLParser.swift \
    Sources/Intelligence/WebContentExtractor.swift \
    Sources/Coordinators/NotificationService.swift \
    Sources/Services/FeedFetcher.swift \
    Sources/Services/JSONFeedParser.swift \
    Sources/Storage/ReadManager.swift \
    Sources/App/ThemeManager.swift \
    Sources/Models/FeedArticle.swift \
    Sources/Storage/CacheManager.swift \
    Sources/Coordinators/FeedManager.swift \
    Sources/App/AppContainer.swift \
    Sources/Views/DesignSystem.swift \
    Sources/Views/GlassSystem.swift \
    Sources/Views/SidebarView.swift \
    Sources/Views/ArticleCardView.swift \
    Sources/Views/ArticleListView.swift \
    Sources/Views/ArticleDetailView.swift \
    Sources/Views/MainView.swift \
    Sources/Views/SettingsView.swift \
    Sources/Storage/SavedStoriesManager.swift \
    Sources/Services/OPMLManager.swift \
    Sources/Views/ArticleWebView.swift \
    Sources/Coordinators/RefreshCoordinator.swift \
    Sources/App/NewsSignposts.swift \
    Sources/App/UpdateChecker.swift \
    Sources/App/NewsApp.swift \
    -o "${MACOS_DIR}/${APP_NAME}"

# Create Info.plist
cat > "${CONTENTS_DIR}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.marspater.news</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleShortVersionString</key>
    <string>2.0</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>LSMinimumSystemVersion</key>
    <string>${LS_MIN_VERSION:-14.0}</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
EOF

echo "Signing binary..."
find "${APP_DIR}" -name ".DS_Store" -delete

# Sign from /tmp to avoid iCloud Drive extended attribute interference
TEMP_APP="/tmp/${APP_DIR}"
rm -rf "${TEMP_APP}"
cp -R "${APP_DIR}" "${TEMP_APP}"
find "${TEMP_APP}" -exec xattr -c {} \; 2>/dev/null || true
find "${TEMP_APP}" -exec xattr -d com.apple.FinderInfo {} \; 2>/dev/null || true
codesign --force --deep --options runtime --entitlements News.entitlements --sign - "${TEMP_APP}"
rm -rf "${APP_DIR}"
cp -R "${TEMP_APP}" "${APP_DIR}"
rm -rf "${TEMP_APP}"

# Force Finder to refresh the app icon cache
touch "${APP_DIR}"

echo "Build complete. App is ready at ${APP_DIR}!"
