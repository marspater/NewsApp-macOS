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
import Network
import os

/// What a later Export Diagnostics needs to reconstruct a network change during a refresh (#929, #927): path changes,
/// resolver outcomes by class and the refresh batches, in memory for this launch only. It holds no host and no URL.
final class NetworkTimeline: Sendable {
    /// The network path as NWPathMonitor reported it, without interface names beyond whether a tunnel is present.
    struct PathState: Equatable, Sendable {
        let status: String
        let interfaceTypes: [String]
        let hasTunnel: Bool

        var description: String {
            let types = interfaceTypes.isEmpty ? "no interface" : interfaceTypes.joined(separator: "+")
            return "\(status), \(types), \(hasTunnel ? "tunnel present" : "no tunnel")"
        }
    }

    /// One timeline event: a path change or a run of resolver outcomes.
    enum Event: Equatable, Sendable {
        /// The path monitor reported this path.
        case path(PathState)
        /// Consecutive lookups of one class share an entry, so a refresh cannot push a path change out of the window.
        case resolver(outcome: String, count: Int)
    }

    /// A timeline event and when it was recorded; a resolver entry's date is its run's first lookup.
    struct Entry: Equatable, Sendable {
        let date: Date
        var event: Event
    }

    /// One refresh batch of feed requests.
    struct Batch: Equatable, Sendable {
        let date: Date
        let attempted: Int
        let failed: Int
        /// Every request failed to connect, so the failures were not held against the feeds.
        let takenForOffline: Bool
        let path: PathState?
        let pathChanged: Bool

        var description: String {
            "\(date.formatted(.iso8601)): \(attempted) requests, \(failed) failed, "
                + "\(takenForOffline ? "taken for offline" : "not taken for offline"), "
                + "path \(path?.description ?? "unknown"), "
                + "\(pathChanged ? "path changed during the batch" : "no path change during the batch")"
        }
    }

    private struct State {
        var entries: [Entry] = []
        var batches: [Batch] = []
        var path: PathState?
        var pathChanges = 0
    }

    /// The launch's timeline, fed by its own path monitor, the gateway's resolver and the feed fetcher.
    static let shared: NetworkTimeline = {
        let timeline = NetworkTimeline()
        timeline.pathMonitor.pathUpdateHandler = { [weak timeline] path in
            timeline?.record(path: PathState(path))
        }
        timeline.pathMonitor.start(queue: DispatchQueue(label: "com.marspater.news.network-timeline"))
        return timeline
    }()
    /// Entries kept; older ones are dropped first.
    static let entryLimit = 50
    /// Refresh batches kept; older ones are dropped first.
    static let batchLimit = 20

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let pathMonitor = NWPathMonitor()
    private let now: @Sendable () -> Date

    /// Creates an empty timeline; tests pass a clock. Only `shared` starts its path monitor.
    init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    deinit { pathMonitor.cancel() }

    /// Records a path report. Every report after the first counts as a change, even when its summary reads the same.
    func record(path: PathState) {
        let date = now()
        state.withLock { state in
            // The monitor's first callback only reports the current path. Every later one is a change, even when this
            // summary reads the same: a route or gateway can move without changing the interface types.
            if state.path != nil { state.pathChanges += 1 }
            state.path = path
            Self.append(Entry(date: date, event: .path(path)), to: &state.entries)
        }
    }

    /// Records a resolver outcome class, extending the last entry when it holds the same class.
    func record(resolverOutcome outcome: String) {
        let date = now()
        state.withLock { state in
            if case .resolver(outcome, let count)? = state.entries.last?.event {
                state.entries[state.entries.count - 1].event = .resolver(outcome: outcome, count: count + 1)
            } else {
                Self.append(Entry(date: date, event: .resolver(outcome: outcome, count: 1)), to: &state.entries)
            }
        }
    }

    /// Records a finished refresh batch with the current path, and whether the path changed since `pathChangesAtStart`.
    func record(attempted: Int, failed: Int, takenForOffline: Bool, pathChangesAtStart: Int) {
        let date = now()
        state.withLock { state in
            let batch = Batch(
                date: date, attempted: attempted, failed: failed, takenForOffline: takenForOffline, path: state.path,
                pathChanged: state.pathChanges != pathChangesAtStart)
            state.batches.append(batch)
            if state.batches.count > Self.batchLimit { state.batches.removeFirst() }
        }
    }

    /// Reported path changes so far; a batch compares it before and after.
    var pathChanges: Int { state.withLock(\.pathChanges) }
    /// The kept events, oldest first.
    var entries: [Entry] { state.withLock(\.entries) }
    /// The kept refresh batches, oldest first.
    var batches: [Batch] { state.withLock(\.batches) }

    private static func append(_ entry: Entry, to entries: inout [Entry]) {
        entries.append(entry)
        if entries.count > entryLimit { entries.removeFirst(entries.count - entryLimit) }
    }

    /// A resolver result's class, without its addresses or any host.
    static func outcomeClass(_ result: IPAddressValidator.ValidationResult) -> String {
        switch result {
        case .allowed: return "allowed"
        case .blocked(let reason):
            return IPAddressValidator.substitution(in: reason).map { "blocked \($0.rawValue)" } ?? "blocked"
        case .noSuchHost: return "noSuchHost"
        case .unresolvable(let reason):
            switch reason {
            case "Timed out": return "unresolvable timeout"
            case "Cancelled": return "cancelled"
            default:
                // Only "dns <code>" and "dns queue" pass: other reasons can be system text naming a host.
                return reason.wholeMatch(of: /dns (-?\d+|queue)/) != nil ? "unresolvable \(reason)" : "unresolvable"
            }
        }
    }
}

extension NetworkTimeline.PathState {
    fileprivate init(_ path: NWPath) {
        let names: [(NWInterface.InterfaceType, String)] = [
            (.wifi, "wifi"), (.wiredEthernet, "wired"), (.cellular, "cellular"), (.other, "other"),
        ]
        let available = path.availableInterfaces
        self.init(
            status: "\(path.status)",
            interfaceTypes: names.filter { type, _ in available.contains { $0.type == type } }.map(\.1),
            hasTunnel: available.contains { interface in
                ["utun", "ipsec", "ppp"].contains { interface.name.hasPrefix($0) }
            })
    }
}
