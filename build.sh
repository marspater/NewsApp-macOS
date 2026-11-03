#!/bin/bash
set -e

APP_NAME="News"
source script/version.sh
APP_DIR="${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

# Deployment target is independent of the SDK and host OS.
TARGET_MACOS="${TARGET_MACOS:-15.0}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/news-module-cache}"
export SWIFT_MODULECACHE_PATH="$CLANG_MODULE_CACHE_PATH"


echo "Building ${APP_NAME} ${NEWS_VERSION} (${NEWS_BUILD}) for macOS ${TARGET_MACOS} (arm64)..."

# Clean old build
rm -rf "${APP_DIR}"

# Create directories
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"
mkdir -p Assets

cp container-migration.plist PrivacyInfo.xcprivacy Sources/ThirdPartyNotices.txt "${RESOURCES_DIR}/"
if [ -d "Sources/Resources/CoreML" ]; then
    mkdir -p "${RESOURCES_DIR}/CoreML"
    cp -r Sources/Resources/CoreML/* "${RESOURCES_DIR}/CoreML/"
fi

# Compile the editable Icon Composer source, including legacy macOS fallback.
xcrun actool "$(pwd)/Assets/AppIcon.icon" --compile "$(pwd)/${RESOURCES_DIR}" \
    --platform macosx --minimum-deployment-target "${TARGET_MACOS}" \
    --app-icon AppIcon --output-partial-info-plist "$(pwd)/${CONTENTS_DIR}/IconInfo.plist"

# Compile Swift files (exclude any standalone scripts)
NEWS_DEPENDENCY_ARCH=arm64
source script/swiftpm_dependencies.sh
# The trailing backslashes stay: harness scripts add their entry points after the `NewsApp.swift \` line.
SWIFT_SOURCES=(
    Sources/Services/DateParser.swift \
    Sources/Models/FeedError.swift \
    Sources/Models/FeedFetchState.swift \
    Sources/Models/FeedCatalog.swift \
    Sources/Models/FeedAdvisory.swift \
    Sources/Models/MuteRules.swift \
    Sources/Services/IPAddressValidator.swift \
    Sources/Models/ArticleIdentity.swift \
    Sources/Models/EventOverview.swift \
    Sources/Models/EventFeed.swift \
    Sources/Models/OnboardingStep.swift \
    Sources/Storage/DatabaseEngine.swift \
    Sources/Storage/DatabaseEngine+Events.swift \
    Sources/Storage/MigrationCoordinator.swift \
    Sources/Storage/SpotlightIndexer.swift \
    Sources/Storage/ArticleStore.swift \
    Sources/Storage/ArticleStore+Spotlight.swift \
    Sources/Storage/ArticleStore+Events.swift \
    Sources/Intelligence/ArticleIntelligence.swift \
    Sources/Intelligence/Overview/OverviewPassageSelector.swift \
    Sources/Intelligence/PromptDefense.swift \
    Sources/Intelligence/Overview/PassageFactExtractor.swift \
    Sources/Intelligence/Tension/TensionMethodology.swift \
    Sources/Intelligence/Tension/WorldTension.swift \
    Sources/Intelligence/Overview/OverviewComposer.swift \
    Sources/Intelligence/Overview/OverviewTimelineBuilder.swift \
    Sources/Intelligence/Overview/OverviewQualityAuditor.swift \
    Sources/Intelligence/Overview/OverviewClaimVerifier.swift \
    Sources/Intelligence/Overview/OverviewTimelineExtractor.swift \
    Sources/Intelligence/Overview/OverviewPerspectivesExtractor.swift \
    Sources/Intelligence/Overview/OverviewThematicAngleExtractor.swift \
    Sources/Intelligence/Overview/OverviewIndustryImpactExtractor.swift \
    Sources/Intelligence/Overview/CoverageSentimentEvaluator.swift \
    Sources/Intelligence/Events/EventCandidates.swift \
    Sources/Intelligence/IntelligencePolicy.swift \
    Sources/Intelligence/Events/ActClass.swift \
    Sources/Intelligence/Events/EventMatcher.swift \
    Sources/Intelligence/Events/EventClustering.swift \
    Sources/Intelligence/Events/SentenceEmbedder.swift \
    Sources/Intelligence/Events/EventJudge.swift \
    Sources/Intelligence/Events/StoryImportance.swift \
    Sources/Intelligence/Extraction/ContentExtractionPipeline.swift \
    Sources/Intelligence/Extraction/EnrichmentQueue.swift \
    Sources/Intelligence/Overview/OverviewGenerationCoordinator.swift \
    Sources/Services/NetworkBoundaryProxy.swift \
    Sources/Views/Reader/WebPreviewPolicy.swift \
    Sources/Services/SecureHTTPClient.swift \
    Sources/App/AppSettings.swift \
    Sources/Services/FeedXMLParser.swift \
    Sources/Coordinators/NotificationService.swift \
    Sources/Coordinators/NotificationImage.swift \
    Sources/Services/FeedFetcher.swift \
    Sources/Services/JSONFeedParser.swift \
    Sources/Storage/ReadManager.swift \
    Sources/App/ThemeManager.swift \
    Sources/Models/FeedArticle.swift \
    Sources/Models/ArchiveSearchToken.swift \
    Sources/Models/ArticleSearchState.swift \
    Sources/Storage/CacheManager.swift \
    Sources/Coordinators/FeedManager.swift \
    Sources/App/AppContainer.swift \
    Sources/Views/DesignSystem.swift \
    Sources/Views/SidebarView.swift \
    Sources/Views/List/ArticleCardView.swift \
    Sources/Views/List/EventCardView.swift \
    Sources/Views/List/ArticleListView.swift \
    Sources/Views/List/StoryQuickLook.swift \
    Sources/Views/Briefing/BriefingComponents.swift \
    Sources/Views/Briefing/BriefingView.swift \
    Sources/Views/Briefing/BriefingHeroCarouselView.swift \
    Sources/Views/Briefing/BriefingBoardLayout.swift \
    Sources/Views/Briefing/BriefingModules.swift \
    Sources/Views/Briefing/BriefingSitrepModule.swift \
    Sources/Views/Briefing/BriefingSinceLastModule.swift \
    Sources/Views/Briefing/BriefingPriorityModule.swift \
    Sources/Views/Briefing/BriefingFootprintModule.swift \
    Sources/Views/Briefing/BriefingRegionsModule.swift \
    Sources/Views/Briefing/BriefingIndustryModule.swift \
    Sources/Views/Briefing/BriefingDriversModule.swift \
    Sources/Views/Briefing/BriefingTimelineModule.swift \
    Sources/Views/Briefing/BriefingWeakSignalsModule.swift \
    Sources/Views/Briefing/BriefingForwardWatchModule.swift \
    Sources/Intelligence/Briefing/ForwardWatchExtractor.swift \
    Sources/Intelligence/Briefing/BriefingSitrepComposer.swift \
    Sources/Storage/DatabaseEngine+Briefing.swift \
    Sources/Views/Reader/ArticleDetailView.swift \
    Sources/Views/Reader/ReaderSupportViews.swift \
    Sources/Views/Reader/ArticleRemoteImage.swift \
    Sources/Views/Reader/EventOverviewReaderView.swift \
    Sources/Views/TensionIndexView.swift \
    Sources/Views/MainView.swift \
    Sources/Views/SettingsView.swift \
    Sources/Views/FeedCatalogView.swift \
    Sources/Views/OnboardingView.swift \
    Sources/Views/List/FeedHealthLine.swift \
    Sources/Storage/SavedStoriesManager.swift \
    Sources/Services/OPMLManager.swift \
    Sources/Views/Reader/ArticleWebView.swift \
    Sources/App/NewsSignposts.swift \
    Sources/App/DiagnosticsExport.swift \
    Sources/App/UpdateChecker.swift \
    Sources/App/NewsURLParser.swift \
    Sources/App/Intents.swift \
    Sources/App/NotificationActionRouter.swift \
    Sources/Views/StoryBanner.swift \
    Sources/App/LibraryBackup.swift \
    Sources/App/NewsApp.swift \
)
source script/app_intents_metadata.sh
source script/sentry_dev.sh
swiftc "${NEWS_DEPENDENCY_FLAGS[@]}" "${NEWS_SENTRY_FLAGS[@]}" "${NEWS_APP_INTENTS_FLAGS[@]}" -swift-version 6 -O -parse-as-library \
    -target "arm64-apple-macos${TARGET_MACOS}" "${SWIFT_SOURCES[@]}" -o "${MACOS_DIR}/${APP_NAME}"
news_app_intents_metadata "${RESOURCES_DIR}" "${TARGET_MACOS}"

# Create Info.plist
cat > "${CONTENTS_DIR}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
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
    <string>${NEWS_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${NEWS_BUILD}</string>
    <key>LSMinimumSystemVersion</key>
    <string>${TARGET_MACOS}</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>CFBundleURLName</key>
            <string>com.marspater.news.feed</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>feed</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>CFBundleURLName</key>
            <string>com.marspater.news.story</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>news</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
EOF
if [[ -n "$SENTRY_DSN" ]]; then
    plutil -insert SentryDSN -string "$SENTRY_DSN" "${CONTENTS_DIR}/Info.plist"
fi
plutil -lint "${CONTENTS_DIR}/Info.plist" >/dev/null

echo "Signing binary..."
find "${APP_DIR}" -name ".DS_Store" -delete

# Sign from /tmp to avoid iCloud Drive extended attribute interference
SIGN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/news-sign.XXXXXX")
TEMP_APP="${SIGN_TMP}/${APP_DIR}"
cp -R "${APP_DIR}" "${TEMP_APP}"
find "${TEMP_APP}" -exec xattr -c {} \; 2>/dev/null || true
find "${TEMP_APP}" -exec xattr -d com.apple.FinderInfo {} \; 2>/dev/null || true
codesign --force --deep --options runtime --entitlements News.entitlements --sign - "${TEMP_APP}"
rm -rf "${APP_DIR}"
cp -R "${TEMP_APP}" "${APP_DIR}"
rm -rf "${SIGN_TMP}"

# Force Finder to refresh the app icon cache
touch "${APP_DIR}"

codesign --verify --deep --strict "${APP_DIR}"

echo "Build complete. App is ready at ${APP_DIR}!"
