import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Comprehensive tests for the News Tension Index historical calibration (#158)
/// and opt-in panel collection beyond user subscriptions (#160).
final class TensionCalibrationTests {

    @MainActor
    static func runAllTests() async throws {
        print("=== Running Tension Index Calibration & Opt-In Collection Tests ===")
        testTensionWeightsProperties()
        testMagnitudeMultiplierLogic()
        testBreadthMultiplierLogic()
        testScaleRawScoreMonotonicityAndSaturation()
        testEventScoringBreakdown()
        testDayScoringSufficientAndInsufficient()
        testGapsNeverTreatedAsZero()
        testSeriesSmoothingWithGaps()
        try await testHistoricalSampleCorpusFixture()
        testAppSettingsOptInDefaultsAndToggle()
        testEffectiveFeedURLsComputation()
        testNotificationIsolationForOptInFeeds()
        print("=== All Tension Calibration & Opt-In Collection Tests Passed! ===")
    }

    // MARK: - 1. Weights and Multipliers

    static func testTensionWeightsProperties() {
        print("  - Testing TensionWeights v1 properties and defaults...")
        let weights = TensionWeights.calibratedV1
        assert(weights.typeWeights[.armedConflict] == 10.0, "armedConflict weight should be 10.0")
        assert(weights.typeWeights[.terrorism] == 8.0, "terrorism weight should be 8.0")
        assert(weights.typeWeights[.disaster] == 6.0, "disaster weight should be 6.0")
        assert(weights.typeWeights[.civilUnrest] == 4.0, "civilUnrest weight should be 4.0")
        assert(weights.typeWeights[.coercion] == 4.0, "coercion weight should be 4.0")
        assert(weights.typeWeights[.healthEmergency] == 4.0, "healthEmergency weight should be 4.0")
        assert(weights.typeWeights[.cyberAttack] == 3.0, "cyberAttack weight should be 3.0")

        assert(weights.scaleFactor == 25.0, "scaleFactor should be 25.0")
        assert(weights.smoothingAlpha == 0.25, "smoothingAlpha should be 0.25 (7-day trailing EMA)")
    }

    static func testMagnitudeMultiplierLogic() {
        print("  - Testing magnitude multiplier selection...")
        let weights = TensionWeights.calibratedV1

        // Deaths dominant
        let dMult = weights.magnitudeMultiplier(deaths: .hundreds, affected: .units)
        assert(dMult == 2.0, "Expected deaths multiplier 2.0 to dominate affected 1.1")

        // Affected dominant
        let aMult = weights.magnitudeMultiplier(deaths: .notReported, affected: .thousands)
        assert(aMult == 2.0, "Expected affected thousands multiplier 2.0 to dominate")

        // Both unrecorded
        let noneMult = weights.magnitudeMultiplier(deaths: .notReported, affected: .notReported)
        assert(noneMult == 1.0, "Expected baseline multiplier 1.0 when no figures reported")
    }

    static func testBreadthMultiplierLogic() {
        print("  - Testing regional breadth multiplier...")
        let weights = TensionWeights.calibratedV1

        assert(weights.breadthMultiplier(regionCount: 0) == 0.85, "0 regions should use single-region baseline")
        assert(weights.breadthMultiplier(regionCount: 1) == 0.85, "1 region should use 0.85")
        assert(weights.breadthMultiplier(regionCount: 2) == 1.0, "2 regions should use 1.0")
        assert(weights.breadthMultiplier(regionCount: 3) == 1.15, "3 regions should use 1.15")
        assert(weights.breadthMultiplier(regionCount: 4) == 1.30, "4 regions should use 1.30")
        assert(weights.breadthMultiplier(regionCount: 6) == 1.30, "6 regions should cap at 1.30")
    }

    static func testScaleRawScoreMonotonicityAndSaturation() {
        print("  - Testing continuous monotonic saturation (0-100)...")
        let weights = TensionWeights.calibratedV1

        let zero = weights.scaleRawScore(0.0)
        assert(zero == 0.0, "Zero raw score must yield 0.0 index")

        let negative = weights.scaleRawScore(-5.0)
        assert(negative == 0.0, "Negative raw score must yield 0.0 index")

        let scores: [Double] = [1.0, 5.0, 10.0, 20.0, 30.0, 50.0, 80.0, 150.0, 500.0]
        var prevIndex: Double = 0.0
        for raw in scores {
            let index = weights.scaleRawScore(raw)
            assert(index > prevIndex, "Scaling must be strictly monotonically increasing for raw=\(raw)")
            assert(index <= 100.0, "Index must never exceed 100.0 for raw=\(raw)")
            prevIndex = index
        }

        // Test saturation towards 100 without hard cliff
        let high = weights.scaleRawScore(250.0)
        assert(high > 99.0 && high <= 100.0, "High raw score must saturate near 100")
    }

    // MARK: - 2. Event and Day Scoring

    static func testEventScoringBreakdown() {
        print("  - Testing event scoring formula...")
        let weights = TensionWeights.calibratedV1

        let bbc = TensionMethodology.v1.panel.first(where: { $0.catalogID == "bbc-world" })!
        let aj = TensionMethodology.v1.panel.first(where: { $0.catalogID == "al-jazeera" })!
        let cbc = TensionMethodology.v1.panel.first(where: { $0.catalogID == "cbc-world" })!

        let classification = TensionEventClassification(
            methodologyVersion: 1,
            type: .armedConflict,
            typeEvidence: ["f1"],
            deaths: .tens, // 1.5
            affected: .units, // 1.1
            magnitudeEvidence: ["f2"],
            escalation: .escalating, // 1.3
            escalationEvidence: ["f3"],
            factCount: 3
        )

        let event = TensionEventDay(
            key: "evt-test-1",
            articleIDs: ["a1", "a2"],
            reporting: [bbc, aj, cbc], // 3 regions -> 1.15
            classification: classification
        )

        let score = TensionCalibrator.scoreEvent(event, weights: weights)
        // raw = 10.0 * 1.5 * 1.3 * 1.15 = 22.425
        let expectedRaw = 10.0 * 1.5 * 1.3 * 1.15
        assert(abs(score.rawScore - expectedRaw) < 0.001, "Expected raw score \(expectedRaw), got \(score.rawScore)")
        assert(score.typeWeight == 10.0)
        assert(score.magnitudeMultiplier == 1.5)
        assert(score.escalationMultiplier == 1.3)
        assert(score.breadthMultiplier == 1.15)

        // Event without counted type
        let untypedClassification = TensionEventClassification(
            methodologyVersion: 1,
            type: nil,
            typeEvidence: [],
            deaths: .notReported,
            affected: .notReported,
            magnitudeEvidence: [],
            escalation: .noSignal,
            escalationEvidence: [],
            factCount: 1
        )
        let untypedEvent = TensionEventDay(
            key: "evt-untyped",
            articleIDs: ["a3"],
            reporting: [bbc],
            classification: untypedClassification
        )
        let untypedScore = TensionCalibrator.scoreEvent(untypedEvent, weights: weights)
        assert(untypedScore.rawScore == 0.0, "Untyped event must have raw score 0.0")
    }

    static func testDayScoringSufficientAndInsufficient() {
        print("  - Testing day scoring under sufficient vs insufficient coverage...")
        let weights = TensionWeights.calibratedV1
        let dayInterval = DateInterval(start: Date(timeIntervalSince1970: 1700000000), duration: 86400)

        // 1. Insufficient coverage
        let insufficientCoverage = TensionCoverage(reporting: [], regions: [], status: .insufficient)
        let insufficientAssessment = TensionDayAssessment(
            methodologyVersion: 1,
            day: dayInterval,
            coverage: insufficientCoverage,
            isProvisional: false,
            events: []
        )
        let insufficientScore = TensionCalibrator.scoreDay(assessment: insufficientAssessment, weights: weights)
        assert(insufficientScore.rawDailyScore == nil, "Insufficient day rawDailyScore must be nil")
        assert(insufficientScore.calibratedIndex == nil, "Insufficient day calibratedIndex must be nil")
        assert(insufficientScore.smoothedIndex == nil, "Insufficient day smoothedIndex must be nil")

        // 2. NoData coverage
        let noDataCoverage = TensionCoverage(reporting: [], regions: [], status: .noData)
        let noDataAssessment = TensionDayAssessment(
            methodologyVersion: 1,
            day: dayInterval,
            coverage: noDataCoverage,
            isProvisional: false,
            events: []
        )
        let noDataScore = TensionCalibrator.scoreDay(assessment: noDataAssessment, weights: weights)
        assert(noDataScore.rawDailyScore == nil, "NoData day rawDailyScore must be nil")
        assert(noDataScore.calibratedIndex == nil, "NoData day calibratedIndex must be nil")
        assert(noDataScore.smoothedIndex == nil, "NoData day smoothedIndex must be nil")

        // 3. Sufficient coverage with quiet day (0 events)
        let sufficientCoverage = TensionCoverage(
            reporting: TensionMethodology.v1.panel,
            regions: TensionMethodology.v1.panelRegions,
            status: .sufficient
        )
        let quietAssessment = TensionDayAssessment(
            methodologyVersion: 1,
            day: dayInterval,
            coverage: sufficientCoverage,
            isProvisional: false,
            events: []
        )
        let quietScore = TensionCalibrator.scoreDay(assessment: quietAssessment, weights: weights)
        assert(quietScore.rawDailyScore == 0.0, "Quiet day raw score should be 0.0")
        assert(quietScore.calibratedIndex == 0.0, "Quiet day calibrated index should be 0.0")
        assert(quietScore.smoothedIndex == 0.0, "Quiet day smoothed index without prior history should be 0.0")
    }

    static func testGapsNeverTreatedAsZero() {
        print("  - Testing normative invariant: gaps are NEVER treated as zero...")
        let weights = TensionWeights.calibratedV1
        let dayStart = Date(timeIntervalSince1970: 1700000000)

        // Day 1: High tension (index ~ 80.0)
        let d1 = TensionDayAssessment(
            methodologyVersion: 1,
            day: DateInterval(start: dayStart, duration: 86400),
            coverage: TensionCoverage(reporting: TensionMethodology.v1.panel, regions: TensionMethodology.v1.panelRegions, status: .sufficient),
            isProvisional: false,
            events: [
                TensionEventDay(
                    key: "e1",
                    articleIDs: ["a1"],
                    reporting: TensionMethodology.v1.panel,
                    classification: TensionEventClassification(
                        methodologyVersion: 1,
                        type: .armedConflict,
                        typeEvidence: ["q1"],
                        deaths: .hundreds,
                        affected: .thousands,
                        magnitudeEvidence: ["q2"],
                        escalation: .escalating,
                        escalationEvidence: ["q3"],
                        factCount: 3
                    )
                )
            ]
        )

        // Day 2: Insufficient data (GAP)
        let d2 = TensionDayAssessment(
            methodologyVersion: 1,
            day: DateInterval(start: dayStart.addingTimeInterval(86400), duration: 86400),
            coverage: TensionCoverage(reporting: [], regions: [], status: .insufficient),
            isProvisional: false,
            events: []
        )

        // Day 3: Sufficient moderate tension (raw = 15.6)
        let d3 = TensionDayAssessment(
            methodologyVersion: 1,
            day: DateInterval(start: dayStart.addingTimeInterval(86400 * 2), duration: 86400),
            coverage: TensionCoverage(reporting: TensionMethodology.v1.panel, regions: TensionMethodology.v1.panelRegions, status: .sufficient),
            isProvisional: false,
            events: [
                TensionEventDay(
                    key: "e3",
                    articleIDs: ["a3"],
                    reporting: Array(TensionMethodology.v1.panel.prefix(5)),
                    classification: TensionEventClassification(
                        methodologyVersion: 1,
                        type: .disaster,
                        typeEvidence: ["q4"],
                        deaths: .hundreds,
                        affected: .thousands,
                        magnitudeEvidence: ["q5"],
                        escalation: .noSignal,
                        escalationEvidence: [],
                        factCount: 2
                    )
                )
            ]
        )

        let scores = TensionCalibrator.scoreSeries(assessments: [d1, d2, d3], weights: weights)
        assert(scores.count == 3)

        // Day 1
        assert(scores[0].calibratedIndex != nil)
        let day1Smoothed = scores[0].smoothedIndex!

        // Day 2 (gap)
        assert(scores[1].calibratedIndex == nil, "Gap day MUST have nil calibrated index")
        assert(scores[1].smoothedIndex == nil, "Gap day MUST have nil smoothed index, never 0.0")

        // Day 3
        assert(scores[2].calibratedIndex != nil)
        let day3Calibrated = scores[2].calibratedIndex!
        let day3Smoothed = scores[2].smoothedIndex!

        // Expected Day 3 smoothed: alpha * day3Calibrated + (1 - alpha) * day1Smoothed
        // It should NOT be: alpha * day3Calibrated + (1 - alpha) * 0.0 !
        let expectedDay3Smoothed = weights.smoothingAlpha * day3Calibrated + (1.0 - weights.smoothingAlpha) * day1Smoothed
        assert(abs(day3Smoothed - expectedDay3Smoothed) < 0.001,
               "Day 3 smoothed must be based on prior valid smoothed value, got \(day3Smoothed), expected \(expectedDay3Smoothed)")
    }

    static func testSeriesSmoothingWithGaps() {
        print("  - Testing chronological EMA smoothing across multiple assessments...")
        let weights = TensionWeights.calibratedV1
        let start = Date(timeIntervalSince1970: 1700000000)

        var assessments: [TensionDayAssessment] = []
        for i in 0..<5 {
            let status: TensionCoverage.Status = (i == 2) ? .insufficient : .sufficient
            let coverage = TensionCoverage(
                reporting: status == .sufficient ? TensionMethodology.v1.panel : [],
                regions: status == .sufficient ? TensionMethodology.v1.panelRegions : [],
                status: status
            )
            assessments.append(
                TensionDayAssessment(
                    methodologyVersion: 1,
                    day: DateInterval(start: start.addingTimeInterval(Double(i * 86400)), duration: 86400),
                    coverage: coverage,
                    isProvisional: false,
                    events: []
                )
            )
        }

        let scored = TensionCalibrator.scoreSeries(assessments: assessments, weights: weights)
        assert(scored.count == 5)
        assert(scored[0].smoothedIndex == 0.0)
        assert(scored[1].smoothedIndex == 0.0)
        assert(scored[2].smoothedIndex == nil, "Day index 2 is insufficient -> must be nil")
        assert(scored[3].smoothedIndex == 0.0)
        assert(scored[4].smoothedIndex == 0.0)
    }

    // MARK: - 3. Historical Corpus Sample Verification

    static func testHistoricalSampleCorpusFixture() async throws {
        print("  - Testing historical sample corpus fixture against Swift classifier and calibrator...")
        var fixtureURL = Bundle.main.url(forResource: "historical-sample", withExtension: "json", subdirectory: "Fixtures/tension-corpus")
        if fixtureURL == nil {
            let localPath = "Tests/Fixtures/tension-corpus/historical-sample.json"
            if FileManager.default.fileExists(atPath: localPath) {
                fixtureURL = URL(fileURLWithPath: localPath)
            }
        }

        guard let fixtureURL else {
            fatalError("Could not locate historical-sample.json fixture")
        }

        let data = try Data(contentsOf: fixtureURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sampleDays = json["sampleDays"] as? [[String: Any]] else {
            fatalError("Malformed historical-sample.json")
        }

        assert(sampleDays.count == 14, "Expected 14 observation days in historical sample")

        let methodology = TensionMethodology.v1
        let weights = TensionWeights.calibratedV1

        var assessments: [TensionDayAssessment] = []

        let isoFormatter = ISO8601DateFormatter()

        for dayDict in sampleDays {
            guard let dayID = dayDict["id"] as? String,
                  let dateStr = dayDict["date"] as? String,
                  let date = isoFormatter.date(from: dateStr),
                  let expectedStatusStr = dayDict["expectedCoverageStatus"] as? String,
                  let reportingFeedIDs = dayDict["reportingFeedCatalogIDs"] as? [String] else {
                fatalError("Invalid day entry in sample")
            }

            let dayInterval = TensionMethodology.day(containing: date)

            // Resolve reporting feeds
            let reportingMembers = methodology.panel.filter { reportingFeedIDs.contains($0.catalogID) }
            let reportingURLs = Set(reportingMembers.map(\.url))
            let coverage = methodology.coverage(reportingFeedURLs: reportingURLs)

            assert(coverage.status.rawValue == expectedStatusStr,
                   "Coverage status mismatch for \(dayID): got \(coverage.status.rawValue), expected \(expectedStatusStr)")

            var eventDays: [TensionEventDay] = []
            if let eventsList = dayDict["events"] as? [[String: Any]] {
                for evtDict in eventsList {
                    guard let evtID = evtDict["id"] as? String,
                          let expDeaths = evtDict["expectedDeaths"] as? String,
                          let expAffected = evtDict["expectedAffected"] as? String,
                          let expEsc = evtDict["expectedEscalation"] as? String,
                          let reportingCatIDs = evtDict["reportingCatalogIDs"] as? [String],
                          let factsList = evtDict["facts"] as? [[String: Any]] else {
                        fatalError("Invalid event entry in \(dayID)")
                    }
                    let expType = evtDict["expectedType"] as? String

                    var facts: [PassageAnchoredFact] = []
                    for fDict in factsList {
                        guard let fid = fDict["id"] as? String,
                              let quote = fDict["quote"] as? String else { continue }
                        facts.append(PassageAnchoredFact(id: fid, statement: quote, passageID: "p-\(fid)", quote: quote, articleID: "art-\(fid)"))
                    }

                    let classification = TensionEventClassifier.classify(facts, methodology: methodology)

                    // Verify classification accuracy
                    assert(classification.type?.rawValue == expType,
                           "Type mismatch in \(evtID): got \(String(describing: classification.type?.rawValue)), expected \(String(describing: expType))")
                    assert(classification.deaths.rawValue == TensionMagnitude.allCases.first(where: { String(describing: $0) == expDeaths })?.rawValue,
                           "Deaths mismatch in \(evtID): got \(classification.deaths), expected \(expDeaths)")
                    assert(classification.affected.rawValue == TensionMagnitude.allCases.first(where: { String(describing: $0) == expAffected })?.rawValue,
                           "Affected mismatch in \(evtID): got \(classification.affected), expected \(expAffected)")
                    assert(classification.escalation.rawValue == expEsc,
                           "Escalation mismatch in \(evtID): got \(classification.escalation.rawValue), expected \(expEsc)")

                    let reportingForEvent = methodology.panel.filter { reportingCatIDs.contains($0.catalogID) }
                    eventDays.append(
                        TensionEventDay(
                            key: evtID,
                            articleIDs: ["art-\(evtID)"],
                            reporting: reportingForEvent,
                            classification: classification
                        )
                    )
                }
            }

            assessments.append(
                TensionDayAssessment(
                    methodologyVersion: methodology.version,
                    day: dayInterval,
                    coverage: coverage,
                    isProvisional: false,
                    events: coverage.status == .sufficient ? eventDays : []
                )
            )
        }

        let scoredSeries = TensionCalibrator.scoreSeries(assessments: assessments, weights: weights)
        assert(scoredSeries.count == 14)

        // Validate Day 1 (major conflict escalation)
        let day1 = scoredSeries[0]
        assert(day1.coverageStatus == .sufficient)
        assert(day1.calibratedIndex! > 80.0, "Day 1 index should be > 80.0, got \(day1.calibratedIndex!)")
        assert(day1.smoothedIndex! > 80.0)

        // Validate Day 6 (routine peaceful day)
        let day6 = scoredSeries[5]
        assert(day6.coverageStatus == .sufficient)
        assert(day6.rawDailyScore == 0.0, "Day 6 raw score should be 0.0")
        assert(day6.calibratedIndex == 0.0, "Day 6 calibrated index should be 0.0")

        // Validate Day 9 (negations)
        let day9 = scoredSeries[8]
        assert(day9.coverageStatus == .sufficient)
        assert(day9.rawDailyScore == 0.0, "Day 9 negations must produce 0.0 raw score")
        assert(day9.calibratedIndex == 0.0, "Day 9 calibrated index must be 0.0")

        // Validate Day 10 (ceasefire collapse reversal)
        let day10 = scoredSeries[9]
        assert(day10.coverageStatus == .sufficient)
        assert(day10.calibratedIndex! > 50.0, "Day 10 ceasefire collapse should be > 50.0, got \(day10.calibratedIndex!)")

        // Validate Day 11 (historical treaty years)
        let day11 = scoredSeries[10]
        assert(day11.coverageStatus == .sufficient)
        assert(day11.rawDailyScore == 0.0, "Day 11 treaty commemoration must produce 0.0 raw score")
        assert(day11.calibratedIndex == 0.0, "Day 11 calibrated index must be 0.0")

        // Validate Days 12, 13, 14 (gaps)
        for i in 11..<14 {
            let gapDay = scoredSeries[i]
            assert(gapDay.coverageStatus != .sufficient)
            assert(gapDay.rawDailyScore == nil, "Gap day \(i) raw score must be nil")
            assert(gapDay.calibratedIndex == nil, "Gap day \(i) calibrated index must be nil")
            assert(gapDay.smoothedIndex == nil, "Gap day \(i) smoothed index must be nil")
        }
    }

    // MARK: - 4. AppSettings & Opt-In Collection (Issue #160)

    @MainActor
    static func testAppSettingsOptInDefaultsAndToggle() {
        print("  - Testing AppSettings tensionCollectionOptIn default and persistence...")
        let suiteName = "test.tension.optin.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        assert(settings.tensionCollectionOptIn == false, "tensionCollectionOptIn must default to false")

        settings.setTensionCollectionOptIn(true)
        assert(settings.tensionCollectionOptIn == true, "tensionCollectionOptIn should be true after update")
        assert(defaults.bool(forKey: AppSettings.tensionCollectionOptInKey) == true, "Should persist to UserDefaults")

        settings.setTensionCollectionOptIn(false)
        assert(settings.tensionCollectionOptIn == false)
        assert(defaults.bool(forKey: AppSettings.tensionCollectionOptInKey) == false)
    }

    @MainActor
    static func testEffectiveFeedURLsComputation() {
        print("  - Testing effectiveFeedURLs computation when opted out vs opted in...")
        let suiteName = "test.effective.urls.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        let originalSubscribed = settings.feedURLs
        assert(!originalSubscribed.isEmpty)

        // When opted out: effectiveFeedURLs == feedURLs
        assert(settings.effectiveFeedURLs == originalSubscribed,
               "When opted out, effectiveFeedURLs must equal user-subscribed feedURLs")
        assert(settings.tensionRetainedFeedURLs.isEmpty, "When opted out, no feed is kept through waiting-story expiry")

        // When opted in: effectiveFeedURLs expands to include all 12 panel feeds
        settings.setTensionCollectionOptIn(true)
        let effective = settings.effectiveFeedURLs
        let panelURLs = TensionMethodology.v1.panel.map(\.url)

        for pURL in panelURLs {
            assert(effective.contains(pURL), "effectiveFeedURLs must contain panel feed: \(pURL)")
        }

        assert(settings.tensionRetainedFeedURLs == panelURLs, "When opted in, exactly the panel feeds outlive waiting-story expiry")

        // Verify no duplicate URLs
        let uniqueCount = Set(effective).count
        assert(uniqueCount == effective.count, "effectiveFeedURLs must not contain duplicates")

        // User's own subscription list remains unaffected
        assert(settings.feedURLs == originalSubscribed, "Subscribing or opting-in must not mutate user's feedURLs")
    }

    static func testNotificationIsolationForOptInFeeds() {
        print("  - Testing that opt-in panel feeds do not produce notifications for non-subscribed feeds...")
        let userFeeds = [TensionMethodology.v1.panel[0].url]
        let panelOnlyFeed = TensionMethodology.v1.panel[1].url

        let articleFromUserFeed = FeedArticle(
            storedID: "art-user-1",
            identityFeedURL: userFeeds[0],
            title: "User Feed Article",
            link: "article-user-1",
            guid: "guid-user-1",
            description: "Desc",
            pubDate: Date(),
            source: "Publisher 1"
        )

        let articleFromPanelFeed = FeedArticle(
            storedID: "art-panel-1",
            identityFeedURL: panelOnlyFeed,
            title: "Panel Only Article",
            link: "article-panel-1",
            guid: "guid-panel-1",
            description: "Desc",
            pubDate: Date(),
            source: "Publisher 2"
        )

        // Simulating FeedManager notification isolation logic:
        let allParsed = [articleFromUserFeed, articleFromPanelFeed]
        let insertedIDs: Set<String> = ["art-user-1", "art-panel-1"]
        let userSubscribed = Set(userFeeds)

        var notifiedIDs = Set<String>()
        let notifiableArticles = allParsed.filter {
            insertedIDs.contains($0.id) &&
            userSubscribed.contains($0.identityFeedURL ?? "") &&
            notifiedIDs.insert($0.id).inserted
        }

        assert(notifiableArticles.count == 1, "Only 1 article should be notifiable")
        assert(notifiableArticles[0].id == "art-user-1", "Only article from user feed should be notifiable")
        assert(!notifiableArticles.contains(where: { $0.id == "art-panel-1" }),
               "Articles from panel feeds that user didn't subscribe to must NEVER notify")
    }
}
