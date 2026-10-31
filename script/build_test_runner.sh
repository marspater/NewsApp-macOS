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
# The headless harnesses (Story Overview sections, reader accessibility, tension calibration) compile into the same
# runner, so a plain ./test.sh builds once; their scripts still build standalone binaries for CI jobs. Both harness
# files declare the reader's command notification names that NewsApp.swift provides in the app; one copy is kept.
sed '/^@main$/d' Tests/EventOverviewAccessibilityTests.swift > "$TEST_STAGE/EventOverviewAccessibilityTests.swift"
sed -e '/^@main$/d' -e '/^extension Notification.Name {$/,/^}$/d' Tests/ReaderAccessibilityTests.swift \
    > "$TEST_STAGE/ReaderAccessibilityTests.swift"
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
            if selected("Tests/BriefingWarRoomTests.swift") { await BriefingWarRoomTests.run() }
            if selected("Tests/BriefingIntelligenceTests.swift") { await BriefingIntelligenceTests.run() }
            if selected("Tests/BriefingImpactTests.swift") { await BriefingImpactTests.run() }
            if selected("Tests/BriefingSignalsTests.swift") { await BriefingSignalsTests.run() }
            if selected("Tests/NewsTests.swift") { await NewsTests.main() }
            // The harness suites run only when named: a targeted runner mode must not pick them up.
            if atom == "Tests/EventOverviewAccessibilityTests.swift" { await EventOverviewAccessibilityTests.main() }
            if atom == "Tests/ReaderAccessibilityTests.swift" { await ReaderAccessibilityTests.main() }
            if atom == "Tests/TensionCalibrationTests.swift" {
                do {
                    try await TensionCalibrationTests.runAllTests()
                    print("✅ All tension calibration tests passed successfully!")
                } catch {
                    print("❌ Tension calibration tests failed: \(error)")
                    exit(1)
                }
            }
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
    Sources/Models/OnboardingStep.swift \
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
    Sources/Intelligence/OverviewIndustryImpactExtractor.swift \
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
    Sources/Views/ArticleCardView.swift \
    Sources/Views/BriefingComponents.swift \
    Sources/Views/BriefingView.swift \
    Sources/Views/BriefingModules.swift \
    Sources/Views/BriefingSitrepModule.swift \
    Sources/Views/BriefingSinceLastModule.swift \
    Sources/Views/BriefingPriorityModule.swift \
    Sources/Views/BriefingFootprintModule.swift \
    Sources/Views/BriefingRegionsModule.swift \
    Sources/Views/BriefingIndustryModule.swift \
    Sources/Views/BriefingDriversModule.swift \
    Sources/Views/BriefingTimelineModule.swift \
    Sources/Views/BriefingWeakSignalsModule.swift \
    Sources/Views/BriefingForwardWatchModule.swift \
    Sources/Intelligence/ForwardWatchExtractor.swift \
    Sources/Intelligence/BriefingSitrepComposer.swift \
    Sources/Storage/DatabaseEngine+Briefing.swift \
    Sources/Views/ArticleRemoteImage.swift \
    Sources/Views/ReaderSupportViews.swift \
    Sources/Views/EventOverviewReaderView.swift \
    Sources/App/NewsSignposts.swift \
    Sources/App/DiagnosticsExport.swift \
    Sources/App/UpdateChecker.swift \
    Sources/App/NewsURLParser.swift \
    Sources/App/Intents.swift \
    Sources/App/NotificationActionRouter.swift \
    Tests/StoryCorpus.swift \
    Tests/ImportanceAudit.swift \
    Tests/OverviewQualityAudit.swift \
    Tests/EventEmbeddingTests.swift \
    Tests/EpicNE2ETests.swift \
    Tests/BriefingE2ETests.swift \
    Tests/BriefingWarRoomTests.swift \
    Tests/BriefingIntelligenceTests.swift \
    Tests/BriefingImpactTests.swift \
    Tests/BriefingSignalsTests.swift \
    Sources/Views/ArticleDetailView.swift \
    Sources/Views/ArticleWebView.swift \
    Tests/TensionCalibrationTests.swift \
    "$TEST_STAGE/EventOverviewAccessibilityTests.swift" "$TEST_STAGE/ReaderAccessibilityTests.swift" \
    "$TEST_STAGE/NewsTests.swift" Tests/FeedKitSwiftSoupTests.swift Tests/NotificationAttachmentTests.swift "$TEST_STAGE/Runner.swift" \
    Tests/TestDefaults.swift \
    -o "$OUTPUT"
