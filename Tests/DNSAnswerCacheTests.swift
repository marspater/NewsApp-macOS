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
import os

/// The validated-answer DNS cache shared by the preflight and the gateway (#929).
enum DNSAnswerCacheTests {
    nonisolated(unsafe) static var checks = 0
    nonisolated(unsafe) static var failures = 0

    static func check(_ value: Bool, _ message: String) {
        checks += 1
        if !value {
            failures += 1
            print("❌ DNSAnswerCache: \(message)")
        }
    }

    /// A settable clock and a count of lookups that reached the "system".
    final class Fixture: Sendable {
        let start = ContinuousClock.now
        let offset = OSAllocatedUnfairLock(initialState: Duration.zero)
        let lookups = OSAllocatedUnfairLock(initialState: 0)
        let answer = OSAllocatedUnfairLock(initialState: IPAddressValidator.ValidationResult.allowed(ips: ["1.1.1.1"]))

        func advance(_ by: Duration) { offset.withLock { $0 += by } }
        var lookupCount: Int { lookups.withLock { $0 } }
        func setAnswer(_ result: IPAddressValidator.ValidationResult) { answer.withLock { $0 = result } }

        func cache(capacity: Int = DNSAnswerCache.defaultCapacity) -> DNSAnswerCache {
            DNSAnswerCache(capacity: capacity, now: { [self] in start.advanced(by: offset.withLock { $0 }) })
        }

        func resolver(_ cache: DNSAnswerCache) -> ProxyResolver {
            ProxyResolver(
                lookup: { [self] _ in
                    lookups.withLock { $0 += 1 }
                    return answer.withLock { $0 }
                }, cache: cache)
        }
    }

    static func checkLifetime() async {
        let fixture = Fixture()
        let cache = fixture.cache()
        let resolver = fixture.resolver(cache)
        var result = await resolver.resolve("example.com")
        check(result == .allowed(ips: ["1.1.1.1"]) && fixture.lookupCount == 1, "a miss looks up")
        result = await resolver.resolve("example.com")
        check(result == .allowed(ips: ["1.1.1.1"]) && fixture.lookupCount == 1, "a hit within the lifetime does not")
        _ = await fixture.resolver(cache).resolve("Example.COM.")
        check(fixture.lookupCount == 1, "preflight and gateway share one answer, whatever the name's spelling")
        fixture.advance(.seconds(59))
        _ = await resolver.resolve("example.com")
        check(fixture.lookupCount == 1, "59 seconds is still inside the lifetime")
        fixture.advance(.seconds(1))
        _ = await resolver.resolve("example.com")
        check(fixture.lookupCount == 2, "an expired answer looks up again")
        _ = await resolver.resolve("other.example")
        check(fixture.lookupCount == 3, "another host has its own answer")
        cache.clear()
        _ = await resolver.resolve("example.com")
        check(fixture.lookupCount == 4, "a cleared cache looks up again")
        // An answer looked up before a path change is never stored after it.
        let before = cache.generation
        cache.clear()
        cache.store(.allowed(ips: ["1.1.1.1"]), for: "stale.example", generation: before)
        check(cache.answer(for: "stale.example") == nil, "an answer from before a clear is dropped")
        cache.store(.allowed(ips: ["1.1.1.1"]), for: "fresh.example", generation: cache.generation)
        check(cache.answer(for: "fresh.example") != nil, "an answer from after a clear is kept")
    }

    static func checkOnlyAllowed() async {
        let answers: [(IPAddressValidator.ValidationResult, String)] = [
            (.blocked(reason: "Private address"), "blocked"), (.noSuchHost, "no such host"),
            (.unresolvable(reason: "dns -1"), "unresolvable"), (.allowed(ips: []), "empty"),
        ]
        for (answer, name) in answers {
            let fixture = Fixture()
            fixture.setAnswer(answer)
            let cache = fixture.cache()
            let resolver = fixture.resolver(cache)
            let first = await resolver.resolve("example.com")
            let second = await resolver.resolve("example.com")
            check(first == answer && second == answer, "\(name) reaches the caller")
            check(fixture.lookupCount == 2 && cache.count == 0, "\(name) is never served from the cache")
        }
        // A filter switched off is noticed on the next lookup; one switched on waits out the lifetime.
        let fixture = Fixture()
        fixture.setAnswer(.blocked(reason: "Filtered"))
        let resolver = fixture.resolver(fixture.cache())
        _ = await resolver.resolve("example.com")
        fixture.setAnswer(.allowed(ips: ["1.1.1.1"]))
        let lifted = await resolver.resolve("example.com")
        check(lifted == .allowed(ips: ["1.1.1.1"]), "lifting a filter shows at once")
        // A deadline or cancellation is not an answer.
        let hang = DNSAnswerCache()
        let slow = ProxyResolver(
            lookup: { _ in
                try? await Task.sleep(for: .seconds(60))
                return .allowed(ips: ["1.1.1.1"])
            }, deadline: .milliseconds(50), cache: hang)
        let timedOut = await slow.resolve("example.com")
        check(timedOut == .unresolvable(reason: "Timed out") && hang.count == 0, "a timeout stores nothing")
        // A cancelled caller is answered "Cancelled", never a stored address.
        let cached = fixture.cache()
        cached.store(.allowed(ips: ["1.1.1.1"]), for: "example.com")
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await fixture.resolver(cached).resolve("example.com")
        }
        let cancelledResult = await cancelled.value
        check(cancelledResult == .unresolvable(reason: "Cancelled"), "cancellation wins over a stored answer")
    }

    static func checkCachedResultsAppearInTimeline() async {
        let fixture = Fixture()
        let timeline = NetworkTimeline()
        let resolver = ProxyResolver(
            lookup: { _ in
                fixture.lookups.withLock { $0 += 1 }
                return .allowed(ips: ["1.1.1.1"])
            }, cache: fixture.cache(), timeline: timeline)
        _ = await resolver.resolve("example.com")
        _ = await resolver.resolve("example.com")
        check(fixture.lookupCount == 1, "a cached answer avoids a second lookup")
        check(
            timeline.entries.last?.event == .resolver(outcome: "allowed", count: 2),
            "the network timeline records both fresh and cached answers")
    }

    static func checkBound() {
        let fixture = Fixture()
        let cache = fixture.cache(capacity: 3)
        for index in 0..<3 {
            cache.store(.allowed(ips: ["1.1.1.1"]), for: "host\(index).example")
            fixture.advance(.seconds(1))
        }
        cache.store(.allowed(ips: ["1.1.1.1"]), for: "host3.example")
        check(cache.count == 3, "entries stay bounded")
        check(cache.answer(for: "host0.example") == nil, "the entry closest to expiring goes first")
        check(cache.answer(for: "host3.example") != nil, "the new answer stays")
        cache.store(.allowed(ips: ["2.2.2.2"]), for: "host1.example")
        check(
            cache.count == 3 && cache.answer(for: "host1.example") == .allowed(ips: ["2.2.2.2"]),
            "a refreshed host replaces its answer without evicting another")
        fixture.advance(.seconds(120))
        cache.store(.allowed(ips: ["1.1.1.1"]), for: "new.example")
        check(cache.count == 1, "a full cache drops what has expired first")
        let none = DNSAnswerCache(capacity: 0)
        none.store(.allowed(ips: ["1.1.1.1"]), for: "example.com")
        check(none.count == 0, "no capacity keeps nothing")
    }

    /// A test's synchronous resolver stays uncached, so scripted answers keep changing between calls.
    static func checkTestResolversStayUncached() async {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let resolver = ProxyResolver(body: { _ in
            calls.withLock { $0 += 1 }
            return .allowed(ips: ["1.1.1.1"])
        })
        _ = await resolver.resolve("example.com")
        _ = await resolver.resolve("example.com")
        check(calls.withLock { $0 } == 2, "a scripted resolver is asked every time")
    }

    static func run() async {
        await checkLifetime()
        await checkOnlyAllowed()
        await checkCachedResultsAppearInTimeline()
        checkBound()
        await checkTestResolversStayUncached()
        print("Finished \(checks) DNS answer cache checks with \(failures) failures.")
        if failures > 0 { exit(1) }
    }
}
