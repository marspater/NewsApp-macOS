// Copyright 2026 Mars Pater
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation

/// The regression runner's entry point (script/build_test_runner.sh builds the NewsTestRunner target). With
/// NEWS_TEST_ATOM set to a Tests/*.swift entry file only that file's tests run; script/test_atoms.sh reads the atoms
/// from the selected(...) calls below.
@main
struct NewsRegressionRunner {
    /// Runs the selected atoms in the order the suites expect; `--parsing-regressions` stops after the parser checks.
    static func main() async {
        let atom = ProcessInfo.processInfo.environment["NEWS_TEST_ATOM"]
        /// Whether `file`'s tests run: every file without NEWS_TEST_ATOM, else the named one.
        func selected(_ file: String) -> Bool { atom == nil || atom == file }
        /// A targeted mode (arguments, no atom) runs only what the mode names; the domain suites stay out of it.
        let targetedMode = atom == nil && CommandLine.arguments.count > 1
        if selected("Tests/FeedKitSwiftSoupTests.swift") { FeedKitSwiftSoupTests.run() }
        if !CommandLine.arguments.contains("--parsing-regressions") {
            if selected("Tests/FeedKitSwiftSoupTests.swift") {
                do { try await FeedKitSwiftSoupTests.runEmbeddingIntegration() } catch {
                    fatalError("Parser/embedding integration failed: \(error)")
                }
            }
            if selected("Tests/NotificationAttachmentTests.swift") {
                NotificationAttachmentTests.run()
                await NotificationAttachmentTests.runBanner()
            }
            if selected("Tests/BriefingE2ETests.swift") { await BriefingE2ETests.run() }
            if selected("Tests/BriefingWarRoomTests.swift") { await BriefingWarRoomTests.run() }
            if selected("Tests/BriefingIntelligenceTests.swift") { await BriefingIntelligenceTests.run() }
            if selected("Tests/BriefingImpactTests.swift") { await BriefingImpactTests.run() }
            if selected("Tests/BriefingSignalsTests.swift") { await BriefingSignalsTests.run() }
            if selected("Tests/KnowledgeEPUBTests.swift") { await KnowledgeEPUBTests.run() }
            if selected("Tests/KnowledgeExportTests.swift") { await KnowledgeExportTests.run() }
            if selected("Tests/AnalysisGenerationTests.swift") { await AnalysisGenerationTests.run() }
            if selected("Tests/EditorialNoveltyTests.swift") { await EditorialNoveltyTests.run() }
            if selected("Tests/EditorialMomentumTests.swift") { await EditorialMomentumTests.run() }
            if selected("Tests/GatewayTimingsTests.swift") { await GatewayTimingsTests.run() }
            if selected("Tests/DNSAnswerCacheTests.swift") { await DNSAnswerCacheTests.run() }
            if selected("Tests/NetworkTimelineTests.swift") { await NetworkTimelineTests.run() }
            if selected("Tests/EditorialWireIdentityTests.swift") { await EditorialWireIdentityTests.run() }
            if selected("Tests/FeedHealthMetricsTests.swift") { await FeedHealthMetricsTests.run() }
            if selected("Tests/EditorialRankingTests.swift") { await EditorialRankingTests.run() }
            if selected("Tests/EditorialPersonalizationTests.swift") { await EditorialPersonalizationTests.run() }
            if selected("Tests/StorageTests.swift"), !targetedMode {
                do { try await StorageTests.run() } catch {
                    print("❌ TEST FAILED with unexpected error: \(error)")
                    exit(1)
                }
            }
            if selected("Tests/NetworkingTests.swift"), !targetedMode {
                do { try await NetworkingTests.run() } catch {
                    print("❌ TEST FAILED with unexpected error: \(error)")
                    exit(1)
                }
            }
            if selected("Tests/MigrationTests.swift"), !targetedMode {
                do { try await MigrationTests.run() } catch {
                    print("❌ TEST FAILED with unexpected error: \(error)")
                    exit(1)
                }
            }
            if selected("Tests/FeedParsingTests.swift"), !targetedMode {
                do { try await FeedParsingTests.run() } catch {
                    print("❌ TEST FAILED with unexpected error: \(error)")
                    exit(1)
                }
            }
            if selected("Tests/ClusteringTests.swift"), !targetedMode {
                do { try await ClusteringTests.run() } catch {
                    print("❌ TEST FAILED with unexpected error: \(error)")
                    exit(1)
                }
            }
            if selected("Tests/IntelligenceTests.swift"), !targetedMode {
                do { try await IntelligenceTests.run() } catch {
                    print("❌ TEST FAILED with unexpected error: \(error)")
                    exit(1)
                }
            }
            if selected("Tests/ReaderTests.swift"), !targetedMode {
                do { try await ReaderTests.run() } catch {
                    print("❌ TEST FAILED with unexpected error: \(error)")
                    exit(1)
                }
            }
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
