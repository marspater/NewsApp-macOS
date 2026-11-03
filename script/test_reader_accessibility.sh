#!/bin/bash
set -e

TARGET_MACOS="${TARGET_MACOS:-15.0}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/news-module-cache}"
export SWIFT_MODULECACHE_PATH="$CLANG_MODULE_CACHE_PATH"

echo "Compiling Reader Accessibility Tests for macOS ${TARGET_MACOS} ($(uname -m))..."
source script/swiftpm_dependencies.sh
swiftc "${NEWS_DEPENDENCY_FLAGS[@]}" -swift-version 6 -O -parse-as-library -target "$(uname -m)-apple-macos${TARGET_MACOS}" \
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
    Sources/Storage/DatabaseEngine.swift \
    Sources/Storage/DatabaseEngine+Events.swift \
    Sources/Storage/DatabaseEngine+Search.swift \
    Sources/Storage/MigrationCoordinator.swift \
    Sources/Storage/ArticleStore.swift \
    Sources/Storage/ArticleStore+Spotlight.swift \
    Sources/Storage/ArticleStore+Events.swift \
    Sources/Storage/SpotlightIndexer.swift \
    Sources/Intelligence/ArticleIntelligence.swift \
    Sources/Intelligence/Overview/OverviewPassageSelector.swift \
    Sources/Intelligence/PromptDefense.swift \
    Sources/Intelligence/Overview/PassageFactExtractor.swift \
    Sources/Intelligence/Tension/TensionMethodology.swift \
    Sources/Intelligence/Tension/WorldTension.swift \
    Sources/Intelligence/Overview/OverviewComposer.swift \
    Sources/Intelligence/Overview/OverviewTimelineBuilder.swift \
    Sources/Intelligence/Overview/OverviewQualityAuditor.swift \
    Sources/Intelligence/Overview/GeneratedTextFidelity.swift \
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
    Sources/Models/SmartBinder.swift \
    Sources/Models/ArchiveSearchToken.swift \
    Sources/Models/ArticleSearchState.swift \
    Sources/Storage/CacheManager.swift \
    Sources/Coordinators/FeedManager.swift \
    Sources/App/AppContainer.swift \
    Sources/Views/DesignSystem.swift \
    Sources/Views/List/ArticleCardView.swift \
    Sources/Views/Reader/ArticleWebView.swift \
    Sources/Views/Reader/ArticleRemoteImage.swift \
    Sources/Views/Reader/EventOverviewReaderView.swift \
    Sources/Views/Reader/ArticleDetailView.swift \
    Sources/Views/Reader/ReaderSupportViews.swift \
    Sources/Views/SmartBinderSheet.swift \
    Sources/Storage/SavedStoriesManager.swift \
    Sources/Services/OPMLManager.swift \
    Sources/App/NewsSignposts.swift \
    Sources/App/UpdateChecker.swift \
    Sources/App/NotificationActionRouter.swift \
    Tests/ReaderAccessibilityTests.swift \
    -o reader_test_runner

echo "Running Reader Accessibility Tests..."
./reader_test_runner "$@"

rm -f reader_test_runner
echo "Reader Accessibility Tests completed successfully."
