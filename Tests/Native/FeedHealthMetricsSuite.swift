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
@Suite struct FeedHealthMetricsSuite {
    private let now = Date(timeIntervalSince1970: 1_793_491_200)

    @Test func noHistoryIsUnknownNotZero() {
        let metrics = FeedHealthMetrics(FeedHealthObservations(), now: now)
        #expect(metrics.successRate == nil)
        #expect(metrics.averageLatency == nil)
        #expect(metrics.extractionClass == .unknown)
    }

    @Test func rateAndLatencyCountSuccessesOnly() {
        let metrics = FeedHealthMetrics(FeedHealthObservations(attempts: 4, successes: 3, latencyTotal: 1.5), now: now)
        #expect(metrics.successRate == 0.75)
        #expect(metrics.averageLatency == 0.5)
    }

    /// The runner's atom, unchanged. It exits the process on a failure, so xctest reports a crash for now; porting its
    /// assertions one by one is #1070's step 2.
    @Test func existingAtomPasses() async {
        await FeedHealthMetricsTests.run()
        #expect(FeedHealthMetricsTests.failures == 0)
    }
}
