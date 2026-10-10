#!/bin/bash
set -e

TARGET_MACOS="${TARGET_MACOS:-15.0}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/news-module-cache}"
export SWIFT_MODULECACHE_PATH="$CLANG_MODULE_CACHE_PATH"

echo "Compiling Event Overview Accessibility Tests for macOS ${TARGET_MACOS} ($(uname -m))..."
swiftc -swift-version 6 -O -parse-as-library -target $(uname -m)-apple-macos${TARGET_MACOS} \
    Sources/Services/DateParser.swift \
    Sources/Models/FeedError.swift \
    Sources/Models/FeedFetchState.swift \
    Sources/Models/FeedCatalog.swift \
    Sources/Models/MuteRules.swift \
    Sources/Services/IPAddressValidator.swift \
    Sources/Models/ArticleIdentity.swift \
    Sources/Models/EventOverview.swift \
    Sources/Models/EventFeed.swift \
    Sources/Storage/DatabaseEngine.swift \
    Sources/Storage/MigrationCoordinator.swift \
    Sources/Storage/ArticleStore.swift \
    Sources/Intelligence/ArticleIntelligence.swift \
    Sources/Intelligence/OverviewPassageSelector.swift \
    Sources/Intelligence/PromptDefense.swift \
    Sources/Intelligence/ModelAvailability.swift \
    Sources/Intelligence/PassageFactExtractor.swift \
    Sources/Intelligence/TensionMethodology.swift \
    Sources/Intelligence/OverviewComposer.swift \
    Sources/Intelligence/OverviewTimelineBuilder.swift \
    Sources/Intelligence/OverviewQualityAuditor.swift \
    Sources/Intelligence/OverviewClaimVerifier.swift \
    Sources/Intelligence/OverviewTimelineExtractor.swift \
    Sources/Intelligence/OverviewPerspectivesExtractor.swift \
    Sources/Intelligence/OverviewThematicAngleExtractor.swift \
    Sources/Intelligence/CoverageSentimentEvaluator.swift \
    Sources/Intelligence/EventCandidates.swift \
    Sources/Intelligence/EventMatcher.swift \
    Sources/Intelligence/EventClustering.swift \
    Sources/Intelligence/EventJudge.swift \
    Sources/Intelligence/StoryImportance.swift \
    Sources/Intelligence/ContentExtractionPipeline.swift \
    Sources/Intelligence/EnrichmentQueue.swift \
    Sources/Intelligence/OverviewGenerationCoordinator.swift \
    Sources/Services/NetworkBoundaryProxy.swift \
    Sources/Views/WebPreviewPolicy.swift \
    Sources/Services/SecureHTTPClient.swift \
    Sources/App/AppSettings.swift \
    Sources/Services/FeedXMLParser.swift \
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
    Sources/Views/ArticleCardView.swift \
    Sources/Views/ArticleWebView.swift \
    Sources/Views/EventOverviewReaderView.swift \
    Sources/Views/ArticleDetailView.swift \
    Sources/Storage/SavedStoriesManager.swift \
    Sources/Services/OPMLManager.swift \
    Sources/Coordinators/RefreshCoordinator.swift \
    Sources/App/NewsSignposts.swift \
    Sources/App/UpdateChecker.swift \
    Tests/EventOverviewAccessibilityTests.swift \
    -o event_overview_test_runner

echo "Running Event Overview Accessibility Tests..."
./event_overview_test_runner "$@"

rm -f event_overview_test_runner
echo "Event Overview Accessibility Tests completed successfully."
