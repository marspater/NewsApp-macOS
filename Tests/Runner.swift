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
        // test.sh runs this once before its pool: it fills the executable's Core ML cache before processes share it.
        if CommandLine.arguments.contains("--warm-models") {
            // Both load whatever the other does, so one failure leaves no model to compile inside the pool.
            let embedder = await SentenceEmbedder.shared.isAvailable
            let scorer = await PairScorer.shared.isAvailable
            exit(embedder && scorer ? 0 : 1)
        }
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
            if selected("Tests/EditorialRankingTests.swift") {
                await EditorialRankingTests.run()
                EditorialRankingEvaluation.leadArmsSmoke()
            }
            if selected("Tests/EditorialPersonalizationTests.swift") { await EditorialPersonalizationTests.run() }
            if selected("Tests/EditorialIntelligenceTests.swift") { await EditorialIntelligenceTests.run() }
            if selected("Tests/TodayLaneAssignmentTests.swift"), !targetedMode {
                do { try await TodayLaneAssignmentTests.run() } catch {
                    recordFailure("TEST FAILED with unexpected error: \(error)")
                }
            }
            if selected("Tests/StorageTests.swift"), !targetedMode {
                do { try await StorageTests.run() } catch {
                    recordFailure("TEST FAILED with unexpected error: \(error)")
                }
            }
            if selected("Tests/NetworkingTests.swift"), !targetedMode {
                do { try await NetworkingTests.run() } catch {
                    recordFailure("TEST FAILED with unexpected error: \(error)")
                }
            }
            if selected("Tests/ClusteringTests.swift"), !targetedMode {
                do { try await ClusteringTests.run() } catch {
                    recordFailure("TEST FAILED with unexpected error: \(error)")
                }
            }
            if selected("Tests/IntelligenceTests.swift"), !targetedMode {
                do { try await IntelligenceTests.run() } catch {
                    recordFailure("TEST FAILED with unexpected error: \(error)")
                }
            }
            if selected("Tests/ReaderTests.swift"), !targetedMode {
                do { try await ReaderTests.run() } catch {
                    recordFailure("TEST FAILED with unexpected error: \(error)")
                }
            }
            if selected("Tests/LifecycleTests.swift"), !targetedMode {
                do { try await LifecycleTests.run() } catch {
                    recordFailure("TEST FAILED with unexpected error: \(error)")
                }
            }
            if selected("Tests/UserInterfaceTests.swift"), !targetedMode {
                do { try await UserInterfaceTests.run() } catch {
                    recordFailure("TEST FAILED with unexpected error: \(error)")
                }
            }
            if selected("Tests/DiagnosticsTests.swift"), !targetedMode {
                do { try await DiagnosticsTests.run() } catch {
                    recordFailure("TEST FAILED with unexpected error: \(error)")
                }
            }
            if selected("Tests/SocketTests.swift"), !targetedMode {
                do { try await SocketTests.run() } catch {
                    recordFailure("TEST FAILED with unexpected error: \(error)")
                }
            }
            if selected("Tests/ActiveWorkCancellationTests.swift"), !targetedMode {
                do { try await ActiveWorkCancellationTests.run() } catch {
                    recordFailure("TEST FAILED with unexpected error: \(error)")
                }
            }
            if selected("Tests/EpicNE2ETests.swift"), !targetedMode { await EpicNE2ETests.run() }
            if selected("Tests/NewsTests.swift") { await NewsTests.main() }
            // The harness suites run only when named: a targeted runner mode must not pick them up.
            if atom == "Tests/EventOverviewAccessibilityTests.swift" { await EventOverviewAccessibilityTests.main() }
            if atom == "Tests/ReaderAccessibilityTests.swift" { await ReaderAccessibilityTests.main() }
            if atom == "Tests/TensionCalibrationTests.swift" {
                do {
                    try await TensionCalibrationTests.runAllTests()
                    print("✅ All tension calibration tests passed successfully!")
                } catch {
                    recordFailure("Tension calibration tests failed: \(error)")
                }
            }
        }
        // Opt-in proof that the summary reports every failure (script/test_failure_report.sh); no pool selects it.
        if atom == "failure-report-self-check" {
            try? await NewsTests.runSuite([
                (
                    "selfCheckFirst",
                    {
                        assertEqual(1, 2, "self-check first failure")
                        throw CocoaError(.userCancelled)
                    }
                ),
                ("selfCheckSecond", { assertTrue(false, "self-check second failure") }),
            ])
        }
        // Every atom ends here: the summary prints each failed test and sets the exit status.
        TestFailureLog.shared.finish()
    }
}
