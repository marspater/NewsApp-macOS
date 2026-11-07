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

extension NativeSuites {
    /// `NEWS_FIXTURE_FEED` replaces the network for the development build only (#1070).
    @Suite struct FixtureFeedSuite {
        private let feed = """
            <rss version="2.0"><channel><title>T</title><item><title>Fixture headline</title>\
            <link>https://example.com/a</link><guid>https://example.com/a</guid></item></channel></rss>
            """

        @Test func releaseBundleAndMissingVariableFetchAsUsual() {
            #expect(
                AppContainer.fixtureFeedBatch(
                    environment: ["NEWS_FIXTURE_FEED": feed], bundleIdentifier: "com.marspater.news") == nil)
            #expect(AppContainer.fixtureFeedBatch(environment: [:], bundleIdentifier: "com.marspater.news.dev") == nil)
        }

        @Test func developmentBuildAnswersWithTheFixture() async throws {
            let batch = try #require(
                AppContainer.fixtureFeedBatch(
                    environment: ["NEWS_FIXTURE_FEED": feed], bundleIdentifier: "com.marspater.news.dev"))
            let results = await batch(["https://example.com/feed", "https://example.org/feed"], false)
            #expect(results.count == 1)
            #expect(results.first?.urlString == "https://example.com/feed")
            #expect(results.first?.articles?.map(\.title) == ["Fixture headline"])
        }
    }
}
