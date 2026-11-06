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

/// Retrospective window classification on event-disjoint synthetic controls, never historical alerts.
enum EditorialMomentumEvaluation {
    struct Report: Decodable {
        let articleID: String
        let wireGroupID: String
        let localPublisherID: String
        let originPublisherID: String
        let publishedAt: Double
        let fetchedAt: Double
        func value(event: String) -> MomentumReport {
            MomentumReport(
                articleID: articleID, eventID: event, wireGroupID: wireGroupID,
                localPublisherID: localPublisherID, originPublisherID: originPublisherID,
                publishedAt: Date(timeIntervalSince1970: publishedAt), fetchedAt: Date(timeIntervalSince1970: fetchedAt)
            )
        }
    }
    struct Case: Decodable {
        let eventID: String
        let scenario: String
        let split: String
        let windowStart: Double
        let through: Double
        let expectedBurst: Bool
        let reports: [Report]
    }
    struct Input: Decodable {
        let basis: String
        let cases: [Case]
    }
    struct Counts {
        var tp = 0
        var fp = 0
        var tn = 0
        var fn = 0
        var latency: [Double] = []
        var scenarios: [String: [Int]] = [:]
        var report: [String: Any] {
            [
                "true_positive": tp, "false_positive": fp, "true_negative": tn, "false_negative": fn,
                "accuracy": Double(tp + tn) / Double(max(1, tp + fp + tn + fn)),
                "false_positive_rate": fp + tn == 0 ? NSNull() : Double(fp) / Double(fp + tn),
                "recall": tp + fn == 0 ? NSNull() : Double(tp) / Double(tp + fn), "latency_ms": latency,
                "by_scenario_tp_fp_tn_fn": scenarios,
            ]
        }
    }

    static func score(_ cases: [Case], configuration: MomentumConfiguration) throws -> Counts {
        var counts = Counts()
        for item in cases {
            let width = item.through - item.windowStart
            guard width > 0, width <= 172800,
                abs(width.truncatingRemainder(dividingBy: configuration.bucketSeconds)) < 0.000001
            else {
                throw CocoaError(.coderInvalidValue)
            }
            let started = ProcessInfo.processInfo.systemUptime
            let summary = try EditorialMomentum.replay(
                reports: item.reports.map { $0.value(event: item.eventID) }, eventID: item.eventID,
                windowStart: Date(timeIntervalSince1970: item.through - 172800),
                through: Date(timeIntervalSince1970: item.through), configuration: configuration)
            counts.latency.append((ProcessInfo.processInfo.systemUptime - started) * 1000)
            let predicted = summary.points.contains {
                $0.bucketEnd.timeIntervalSince1970 > item.windowStart && $0.state == .accelerating
            }
            let index: Int
            switch (predicted, item.expectedBurst) {
            case (true, true):
                counts.tp += 1
                index = 0
            case (true, false):
                counts.fp += 1
                index = 1
            case (false, false):
                counts.tn += 1
                index = 2
            case (false, true):
                counts.fn += 1
                index = 3
            }
            var scenario = counts.scenarios[item.scenario, default: [0, 0, 0, 0]]
            scenario[index] += 1
            counts.scenarios[item.scenario] = scenario
        }
        return counts
    }

    static func fields(_ value: MomentumConfiguration) -> [String: Any] {
        [
            "bucket_seconds": value.bucketSeconds, "short_half_life": value.shortHalfLife,
            "long_half_life": value.longHalfLife, "signal_half_life": value.signalHalfLife,
            "volume_window": value.volumeWindow, "independent_report_floor": value.minimumIndependentReports,
            "origin_publisher_floor": value.minimumOriginPublishers,
        ]
    }

    static func candidates() -> [MomentumConfiguration] {
        var values: [MomentumConfiguration] = []
        for short in [1800.0, 3600.0] {
            for long in [10800.0, 21600.0] {
                for signal in [1800.0, 3600.0] {
                    for floor in [3, 5, 10, 20] {
                        for origins in [2, 3] {
                            values.append(
                                MomentumConfiguration(
                                    bucketSeconds: 300, shortHalfLife: short, longHalfLife: long,
                                    signalHalfLife: signal, volumeWindow: 3600, minimumIndependentReports: floor,
                                    minimumOriginPublishers: origins))
                        }
                    }
                }
            }
        }
        return values
    }

    static func run(input: URL, output: URL) async throws {
        let data = try Data(contentsOf: input)
        let fixture = try JSONDecoder().decode(Input.self, from: data)
        let tune = fixture.cases.filter { $0.split == "tune" }
        let holdout = fixture.cases.filter { $0.split == "holdout" }
        guard fixture.basis == "synthetic_phase_zero_controls", fixture.cases.count == 50,
            Set(fixture.cases.map(\.eventID)).count == 50, tune.count == 25, holdout.count == 25,
            Set(tune.map(\.eventID)).isDisjoint(with: Set(holdout.map(\.eventID)))
        else { throw CocoaError(.coderInvalidValue) }
        var best: (MomentumConfiguration, Counts)?
        var sweep: [[String: Any]] = []
        for config in candidates() {
            let counts = try score(tune, configuration: config)
            sweep.append(["configuration": fields(config), "metrics": counts.report])
            if best == nil || counts.fp < best!.1.fp || (counts.fp == best!.1.fp && counts.tp > best!.1.tp) {
                best = (config, counts)
            }
        }
        guard let selected = best else { throw CocoaError(.coderInvalidValue) }
        let held = try score(holdout, configuration: selected.0)
        let report: [String: Any] = [
            "schema_version": 1, "phase": 2, "basis": fixture.basis,
            "input_sha256": ArticleIdentity.sha256Hex(String(decoding: data, as: UTF8.self)),
            "build_configuration": ProcessInfo.processInfo.environment["NEWS_EDITORIAL_BUILD_CONFIGURATION"]
                ?? "unspecified",
            "selection_rule": "fewest tune false positives, then most true positives, then first configuration",
            "selected_configuration": fields(selected.0), "tune_sweep": sweep, "holdout": held.report,
            "tune_events": tune.count, "holdout_events": holdout.count,
            "replay_horizon_hours": 48,
            "window_policy": "retrospective final-as-of-through; not historical alert predictions",
            "database_update_latency_ms": NSNull(), "database_status": "production persistence not wired",
            "production_readiness": "not_established",
            "limitations": [
                "Synthetic breaking/quiet/syndication controls do not establish real-news accuracy.",
                "Zero-seeded EMAs and informational warmup are explicit; parameters are not shipping defaults.",
            ],
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
            to: output, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        print("Momentum experiment wrote \(output.path)")
    }
}
