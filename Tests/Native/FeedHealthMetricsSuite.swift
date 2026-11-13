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
import Testing

/// Proof of the native target (#1070): Swift Testing over the same sources and test helpers the custom runner compiles.
extension NativeSuites {
    @Suite(.tags(.feedHealth)) struct FeedHealthMetricsSuite {
        private let now = Date(timeIntervalSince1970: 1_793_491_200)

        @Test func noHistoryIsUnknownNotZero() {
            let metrics = FeedHealthMetrics(FeedHealthObservations(), now: now)
            #expect(metrics.successRate == nil)
            #expect(metrics.averageLatency == nil)
            #expect(metrics.extractionClass == .unknown)
        }

        @Test func rateAndLatencyCountSuccessesOnly() {
            let metrics = FeedHealthMetrics(
                FeedHealthObservations(attempts: 4, successes: 3, latencyTotal: 1.5), now: now)
            #expect(metrics.successRate == 0.75)
            #expect(metrics.averageLatency == 0.5)
        }

        /// #715: the inspector's one query answers for a library of 150 feeds, each with its own samples and stories.
        @Test(.tags(.integration)) func oneQueryAnswersForOneHundredAndFiftyFeeds() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "news-feed-health-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let database = DatabaseEngine(path: directory.appendingPathComponent("library.sqlite3").path)
            try await database.open()
            let feeds = (0..<150).map { "https://feed\($0).example/feed.xml" }
            for (index, feed) in feeds.enumerated() {
                let stories = (0..<4).map { story in
                    FeedArticle(
                        storedID: "f\(index)-\(story)", title: "Headline \(index)-\(story)",
                        link: "https://feed\(index).example/\(story)", guid: "f\(index)-\(story)", description: "Blurb",
                        pubDate: now.addingTimeInterval(-Double(story + 1) * 86_400), source: "Outlet \(index)",
                        readerDocument: ReaderDocument(version: 1, blocks: [], isComplete: story < 3))
                }
                try await database.upsertArticles(stories, feedUrl: feed, now: now)
                try await database.recordFeedSuccess(feed, at: now)
                try await database.recordFeedSample(feed, latency: 0.5)
                try await database.recordFeedSample(feed, latency: index.isMultiple(of: 2) ? 0.5 : nil)
            }

            let metrics = try await database.feedHealthMetrics(now: now)
            #expect(Set(metrics.keys) == Set(feeds))
            #expect(metrics.values.allSatisfy { $0.assessedStories == 4 && $0.fullReaderShare == 0.75 })
            #expect(metrics[feeds[0]]?.successRate == 1)
            #expect(metrics[feeds[1]]?.successRate == 0.5)
            await database.close()
        }

        /// Run the existing atom without terminating the native test process on failure.
        @Test func existingAtomPasses() async {
            await FeedHealthMetricsTests.run(exitOnFailure: false)
            #expect(FeedHealthMetricsTests.failures == 0)
        }
    }
}
