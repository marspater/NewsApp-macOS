#!/bin/bash
# Compile the regression runner used by ./test.sh and script/ci_testsuite.sh.
# usage: script/build_test_runner.sh OUTPUT [extra swiftc flags...]
# Run OUTPUT with NEWS_TEST_ATOM set to a Tests/*.swift entry file to run only that file's tests.
set -e

cd "$(dirname "$0")/.."
OUTPUT="$1"
shift

TARGET_MACOS="${TARGET_MACOS:-15.0}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/news-module-cache}"
export SWIFT_MODULECACHE_PATH="$CLANG_MODULE_CACHE_PATH"

TEST_STAGE=$(mktemp -d "${TMPDIR:-/tmp}/news-tests.XXXXXX")
trap 'rm -rf "$TEST_STAGE"' EXIT
# Keep the existing runner unchanged while including the dedicated parsing checks in every full regression run.
sed '/^@main$/d' Tests/NewsTests.swift > "$TEST_STAGE/NewsTests.swift"
cat > "$TEST_STAGE/Runner.swift" <<'SWIFT'
import Foundation

@main
struct NewsRegressionRunner {
    static func main() async {
        let atom = ProcessInfo.processInfo.environment["NEWS_TEST_ATOM"]
        func selected(_ file: String) -> Bool { atom == nil || atom == file }
        if selected("Tests/FeedKitSwiftSoupTests.swift") { FeedKitSwiftSoupTests.run() }
        if !CommandLine.arguments.contains("--parsing-regressions") {
            if selected("Tests/FeedKitSwiftSoupTests.swift") {
                do { try await FeedKitSwiftSoupTests.runEmbeddingIntegration() }
                catch { fatalError("Parser/embedding integration failed: \(error)") }
            }
            if selected("Tests/NotificationAttachmentTests.swift") { NotificationAttachmentTests.run() }
            if selected("Tests/BriefingE2ETests.swift") { await BriefingE2ETests.run() }
            if selected("Tests/NewsTests.swift") { await NewsTests.main() }
        }
    }
}
SWIFT

echo "Compiling tests for macOS ${TARGET_MACOS} ($(uname -m))..."
source script/swiftpm_dependencies.sh
swiftc "${NEWS_DEPENDENCY_FLAGS[@]}" "$@" -target "$(uname -m)-apple-macos${TARGET_MACOS}" \
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
    Sources/Models/ArchiveSearchToken.swift \
    Sources/Storage/DatabaseEngine.swift \
    Sources/Storage/DatabaseEngine+Events.swift \
    Sources/Storage/MigrationCoordinator.swift \
    Sources/Storage/SpotlightIndexer.swift \
    Sources/Storage/ArticleStore.swift \
    Sources/Intelligence/ArticleIntelligence.swift \
    Sources/Intelligence/OverviewPassageSelector.swift \
    Sources/Intelligence/PromptDefense.swift \
    Sources/Intelligence/PassageFactExtractor.swift \
    Sources/Intelligence/TensionMethodology.swift \
    Sources/Intelligence/WorldTension.swift \
    Sources/Intelligence/OverviewComposer.swift \
    Sources/Intelligence/OverviewTimelineBuilder.swift \
    Sources/Intelligence/OverviewQualityAuditor.swift \
    Sources/Intelligence/OverviewClaimVerifier.swift \
    Sources/Intelligence/OverviewTimelineExtractor.swift \
    Sources/Intelligence/OverviewPerspectivesExtractor.swift \
    Sources/Intelligence/OverviewThematicAngleExtractor.swift \
    Sources/Intelligence/CoverageSentimentEvaluator.swift \
    Sources/Intelligence/EventCandidates.swift \
    Sources/Intelligence/IntelligencePolicy.swift \
    Sources/Intelligence/ActClass.swift \
    Sources/Intelligence/EventMatcher.swift \
    Sources/Intelligence/EventClustering.swift \
    Sources/Intelligence/SentenceEmbedder.swift \
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
    Sources/Storage/SavedStoriesManager.swift \
    Sources/Services/OPMLManager.swift \
    Sources/Views/DesignSystem.swift \
    Sources/Views/BriefingComponents.swift \
    Sources/Views/BriefingView.swift \
    Sources/Views/ArticleRemoteImage.swift \
    Sources/Views/ReaderSupportViews.swift \
    Sources/Views/EventOverviewReaderView.swift \
    Sources/App/NewsSignposts.swift \
    Sources/App/UpdateChecker.swift \
    Sources/App/NewsURLParser.swift \
    Sources/App/Intents.swift \
    Sources/App/NotificationActionRouter.swift \
    Tests/StoryCorpus.swift \
    Tests/OverviewQualityAudit.swift \
    Tests/EventEmbeddingTests.swift \
    Tests/EpicNE2ETests.swift \
    Tests/BriefingE2ETests.swift \
    "$TEST_STAGE/NewsTests.swift" Tests/FeedKitSwiftSoupTests.swift Tests/NotificationAttachmentTests.swift "$TEST_STAGE/Runner.swift" \
    Tests/TestDefaults.swift \
    -o "$OUTPUT"
