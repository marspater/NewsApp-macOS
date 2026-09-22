#!/bin/bash
set -e

HOST_MACOS_VER=$(sw_vers -productVersion 2>/dev/null | cut -d. -f1,2 || echo "27.0")
TARGET_MACOS="${TARGET_MACOS:-$HOST_MACOS_VER}"

echo "Compiling tests for macOS ${TARGET_MACOS} ($(uname -m))..."
swiftc -target $(uname -m)-apple-macos${TARGET_MACOS} \
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
    Sources/Storage/SavedStoriesManager.swift \
    Sources/Services/OPMLManager.swift \
    Sources/Views/DesignSystem.swift \
    Sources/Views/GlassSystem.swift \
    Sources/Coordinators/RefreshCoordinator.swift \
    Sources/App/NewsSignposts.swift \
    Sources/App/UpdateChecker.swift \
    Tests/NewsTests.swift \
    -o test_runner

echo "Running unit tests..."
./test_runner

# Clean up
rm -f test_runner
