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

import AppIntents
import AppKit
import CryptoKit
import Darwin
import Foundation
import ImageIO
import NaturalLanguage
import Network
import Observation
import PDFKit
import SQLite3
import SwiftUI
import Testing
import UniformTypeIdentifiers
import UserNotifications
import WebKit
import dnssd
import os

#if canImport(FoundationModels)
    import FoundationModels
#endif

extension NativeSuites.LifecycleSuite {
    static func testNotificationServiceErrorLogging() async {
        print("  - Testing NotificationService Formatting & Robust Dispatching...")

        // The runner has no bundle identifier, so the shared service's banner delivery returns at once; xctest has one,
        // and UNUserNotificationCenter raises outside an app bundle. A service whose post does nothing keeps the
        // runner's path.
        let service = NotificationService(post: { _ in })

        // 1. Singular grammar
        let singularSummary = NotificationService.formatMinimalSummary(articleCount: 1, uniqueSourcesCount: 1)
        expectEqual(singularSummary, "1 new article from 1 source", "Singular grammar check")

        // 2. Plural grammar
        let pluralSummary = NotificationService.formatMinimalSummary(articleCount: 5, uniqueSourcesCount: 3)
        expectEqual(pluralSummary, "5 new articles across 3 sources", "Plural grammar check")

        // Edge cases
        expectEqual(
            NotificationService.formatMinimalSummary(articleCount: 1, uniqueSourcesCount: 0),
            "1 new article across 0 sources", "Edge case: 1 article, 0 sources")
        expectEqual(
            NotificationService.formatMinimalSummary(articleCount: 0, uniqueSourcesCount: 0),
            "0 new articles across 0 sources", "Edge case: 0 articles, 0 sources")
        expectEqual(
            NotificationService.formatMinimalSummary(articleCount: 0, uniqueSourcesCount: 1),
            "0 new articles from 1 source", "Edge case: 0 articles, 1 source")

        // 3. Importance computation range [0.0, 1.0]
        expectEqual(
            NotificationService.breakingSignalWeight(in: "Studies show diesel bodies replacement"), 0,
            "Signal words match whole words only")
        expectEqual(
            NotificationService.breakingSignalWeight(in: "Man dies in attack, police say"), 2,
            "Whole-word breaking signals weigh a point each")
        expectEqual(
            NotificationService.breakingSignalWeight(in: "President announces the company launches a fund"), 1.5,
            "Announcement and office-holder words weigh half (#545)")
        let score = service.computeImportance(
            title: "Breaking News: Major Crisis Declared", description: "Officials announce emergency response.")
        expectTrue(score >= 0.0 && score <= 1.0, "Score must be bounded between 0.0 and 1.0")
        // The score is remembered per text (#937): a second service works it out afresh and must agree.
        expectEqual(
            service.computeImportance(
                title: "Breaking News: Major Crisis Declared", description: "Officials announce emergency response."),
            score, "A remembered score is the score")
        expectEqual(
            NotificationService().computeImportance(
                title: "Breaking News: Major Crisis Declared", description: "Officials announce emergency response."),
            score, "A remembered score equals a fresh one")

        // One banner per event (#523): the strongest report represents its event; singles stand alone.
        func report(_ id: Int, _ title: String) -> FeedArticle {
            FeedArticle(
                title: title, link: "https://notify.invalid/\(id)", guid: "notify-\(id)", description: "",
                pubDate: Date(timeIntervalSince1970: 1_700_000_000), source: "Publisher \(id)")
        }
        let quiet = report(1, "Council meets on Tuesday")
        let loud = report(
            2,
            "Breaking: explosion kills dozens in Paris, London, Berlin, Madrid, Rome, Vienna, Lisbon and Dublin; emergency declared"
        )
        let third = report(3, "Explosion reported downtown")
        let single = report(4, "Local library extends opening hours")
        let events = [quiet.id: "event-a", loud.id: "event-a", third.id: "event-a"]
        let chosen = await NotificationService.representatives(of: [quiet, loud, third, single], events: events)
        expectEqual(
            chosen.map(\.article.id), [loud.id, single.id], "One report per event, the strongest, then the single")
        let alone = await NotificationService.representatives(of: [quiet, single], events: [:])
        expectEqual(alone.map(\.article.id), [quiet.id, single.id], "Without events every story stands alone in order")

        // 4. Robust dispatching (no crashes across all 3 notification tiers)
        let sampleArticle = FeedArticle(
            title: "Urgent Update", link: "https://example.com/urgent", guid: "sample-guid",
            description: "Details follow", pubDate: Date(), source: "Wire Service")
        await service.triageAndNotify(newArticles: [sampleArticle], delivery: .init(mode: .minimal))
        await service.triageAndNotify(newArticles: [sampleArticle], delivery: .init(mode: .privacy))
        await service.triageAndNotify(newArticles: [sampleArticle], delivery: .init(mode: .full))

        // 5. Banners arrive one at a time, a pause apart, threaded per story (#587): two new reports of one event are
        // one banner; three events are three spaced banners with their own threads. A breaking story is an active
        // banner with sound; a lesser one is silent.
        struct Posted: Sendable {
            let at = ContinuousClock.now
            let thread: String
            let sound: Bool
            let body: String
            let actions: Bool
            init(_ banner: StoryBanner) {
                thread = banner.thread
                sound = banner.sound
                body = banner.body
                actions = banner.actions
            }
        }
        actor Recorder {
            var posted: [Posted] = []
            func record(_ item: Posted) { posted.append(item) }
        }
        let recorder = Recorder()
        let spaced = NotificationService(post: { await recorder.record(Posted($0)) }, spacing: .milliseconds(60))
        // Three signal words and six named places put a score at 0.75 before sentiment, so these are breaking
        // whatever the sentiment tagger says.
        let fourth = report(
            5,
            "Earthquake kills hundreds in Tokyo, Osaka, Kyoto, Nagoya, Sapporo, Kobe and Sendai; emergency declared as crisis deepens"
        )
        let fifth = report(
            6,
            "Explosion at a refinery in Houston, Dallas, Austin, Denver, Phoenix, Tucson and Boise, dozens killed; urgent evacuation"
        )
        let pairEvents = [quiet.id: "event-a", loud.id: "event-a", fourth.id: "event-b", fifth.id: "event-c"]
        await spaced.triageAndNotify(
            newArticles: [quiet, loud, fourth, fifth], delivery: .init(mode: .full, events: pairEvents))
        let posted = await recorder.posted
        expectEqual(posted.count, 3, "Two reports of one event and two other events are three banners")
        expectEqual(
            Set(posted.map(\.thread)), ["event-a", "event-b", "event-c"], "Each banner is threaded under its event")
        expectTrue(
            zip(posted, posted.dropFirst()).allSatisfy { $1.at - $0.at >= .milliseconds(60) },
            "Banners of one refresh are posted at least the spacing apart")
        expectTrue(posted.allSatisfy(\.sound), "Breaking stories are banners with sound")
        expectTrue(posted.allSatisfy(\.actions), "A story's banner carries Save, Mark as Read and Open (#560)")
        // Banners are minutes apart, so the pass asks before each one whether full banners are still allowed.
        let haltedRecorder = Recorder()
        let halted = NotificationService(post: { await haltedRecorder.record(Posted($0)) }, spacing: .zero)
        var haltedDelivery = NotificationDelivery(mode: .full, events: pairEvents)
        let asked = NewsTests.TestCounter()
        // Allowed until the first banner posts, refused from then on.
        haltedDelivery.continues = {
            await asked.increment()
            return await haltedRecorder.posted.isEmpty
        }
        await halted.triageAndNotify(newArticles: [quiet, loud, fourth, fifth], delivery: haltedDelivery)
        expectEqual(
            (await haltedRecorder.posted).count, 1,
            "Once the settings no longer allow full banners, the pass stops after the banner already posting")
        expectEqual(await asked.value, 3, "A halt ends the pass: no further gap is waited out and asked again")
        let quietRecorder = Recorder()
        let quietService = NotificationService(post: { await quietRecorder.record(Posted($0)) }, spacing: .zero)
        await quietService.triageAndNotify(newArticles: [quiet], delivery: .init(mode: .full))
        expectTrue(
            (await quietRecorder.posted).allSatisfy { !$0.sound },
            "A story below the breaking score is silent when it notifies")
        let minimalRecorder = Recorder()
        let minimal = NotificationService(post: { await minimalRecorder.record(Posted($0)) }, spacing: .zero)
        await minimal.triageAndNotify(
            newArticles: [quiet, loud, third, single], delivery: .init(mode: .minimal, events: events))
        expectEqual(
            (await minimalRecorder.posted).first?.body, "2 new articles across 2 sources",
            "Summary modes count one report per event too")
        expectFalse((await minimalRecorder.posted).first?.actions ?? true, "A summary banner has no story actions")

        // 6. Normal lane (#588, #665): of 100 new stories, three are breaking, every fourth is Technology (a top
        // interest) and every tenth event has three publishers. At most five normal banners in the rolling hour.
        var seeded: [(article: FeedArticle, score: Double)] = []
        var seededEvents: [String: String] = [:]
        var publishers: [String: Int] = [:]
        for index in 0..<100 {
            var article = report(100 + index, "Story \(index)")
            article.category = ["Technology", "Food", "Travel", "Sports"][index % 4]
            article.identityFeedURL = "https://other.invalid/feed"
            seededEvents[article.id] = "seeded-\(index)"
            publishers["seeded-\(index)"] = index % 10 == 0 ? 3 : 1
            seeded.append((article, index < 3 ? 0.7 : 0.3))
        }
        var delivery = NotificationDelivery(mode: .full, events: seededEvents)
        delivery.publishers = publishers
        delivery.interests = NotificationService.topInterests(["technology": 9, "politics": 4, "world": 2, "food": 1])
        expectEqual(
            NotificationService.rankedInterests(["technology": 9, "politics": 4, "world": 2, "food": 1]),
            ["technology", "politics", "world"], "The top three interests by weight")
        func planned(_ delivery: NotificationDelivery, pending: [String: [(article: FeedArticle, score: Double)]] = [:])
            -> [String]
        {
            NotificationService.plan(new: seeded, pending: pending, delivery: delivery).banners.map {
                $0.article?.title ?? NotificationService.groupedBody($0)
            }
        }
        expectEqual(
            planned(delivery), ["Story 0", "Story 1", "Story 2", "Story 20", "Story 40"],
            "Breaking stories and top-interest stories with three publishers notify, strongest first, five at most")
        delivery.ledger.normalLastHour = 3
        expectEqual(planned(delivery), ["Story 0", "Story 1"], "The rolling hour's earlier banners use the allowance")
        delivery.ledger.normalLastHour = 5
        expectTrue(planned(delivery).isEmpty, "A full hour posts no normal banner")
        delivery.ledger.normalLastHour = 0
        delivery.interests = []
        expectEqual(
            planned(delivery), ["Story 0", "Story 1", "Story 2"], "Without interests only breaking stories notify")

        // 7. Repeated events (#545, #665): an event announced today stays quiet while its lead headline is the one
        // announced, unless it rises to a higher lane; a new lead headline notifies again.
        delivery.leadTitles = ["seeded-1": "Story 1 lead"]
        delivery.ledger.announced = [
            "seeded-1": .init(leadKey: EventFeedSummary.titleKey("Story 1 lead"), lane: .normal)
        ]
        expectEqual(planned(delivery), ["Story 0", "Story 2"], "A second report of an announced event does not notify")
        delivery.ledger.announced["seeded-1"]?.leadKey = EventFeedSummary.titleKey("An earlier lead")
        expectEqual(planned(delivery), ["Story 0", "Story 1", "Story 2"], "A changed lead headline notifies again")

        // 8. Starred lane: one banner per feed and 20 minutes, standing for every pending story (#665).
        let starredFeed = "https://starred.invalid/feed"
        func starredStory(_ index: Int, event: String? = nil) -> (article: FeedArticle, score: Double) {
            var article = FeedArticle(
                title: "Starred \(index)", link: "https://notify.invalid/\(500 + index)", guid: "notify-\(500 + index)",
                description: "", pubDate: Date(timeIntervalSince1970: 1_700_000_000), source: "Starred Daily")
            article.identityFeedURL = starredFeed
            if let event { delivery.events[article.id] = event }
            return (article, 0.3)
        }
        delivery.starredFeedURLs = [starredFeed]
        delivery.ledger.announced = [:]
        let one = [starredFeed: [starredStory(1)]]
        expectTrue(planned(delivery, pending: one).contains("Starred 1"), "One pending story is an individual banner")
        let burst = (0..<20).map { starredStory($0) }
        let grouped = NotificationService.plan(new: seeded, pending: [starredFeed: burst], delivery: delivery).banners
            .filter { $0.lane == .starred }
        expectEqual(grouped.count, 1, "Twenty stories from a starred feed are one banner, not twenty")
        expectEqual(grouped.first?.title, "Starred Daily", "A grouped starred banner is titled with the feed")
        expectEqual(grouped.first?.thread, "starred-\(starredFeed)", "Grouped starred banners share a feed thread")
        expectTrue(
            grouped.first.map(NotificationService.groupedBody)?.hasPrefix("20 new stories\nStarred ") == true,
            "The grouped body counts the stories, then two headlines")
        delivery.ledger.lastStarred[starredFeed] = delivery.now.addingTimeInterval(-10 * 60)
        expectFalse(planned(delivery, pending: one).contains("Starred 1"), "Within 20 minutes the feed stays pending")
        delivery.ledger.lastStarred[starredFeed] = delivery.now.addingTimeInterval(-21 * 60)
        expectTrue(planned(delivery, pending: one).contains("Starred 1"), "After 20 minutes its pending stories post")
        delivery.starredFeedURLs = []
        expectFalse(planned(delivery, pending: one).contains("Starred 1"), "Unstarring stops the feed's banners")
        delivery.starredFeedURLs = [starredFeed]

        // B: an event announced only as normal rises to starred; one announced as starred posts no individual banner,
        // but its story still counts in the feed's next group.
        let risen = [starredFeed: [starredStory(30, event: "known")]]
        delivery.ledger.announced = ["known": .init(leadKey: EventFeedSummary.titleKey("Starred 30"), lane: .normal)]
        expectTrue(planned(delivery, pending: risen).contains("Starred 30"), "Normal → starred notifies")
        delivery.ledger.announced["known"]?.lane = .starred
        expectFalse(planned(delivery, pending: risen).contains("Starred 30"), "A starred event does not repeat")
        let mixed = NotificationService.plan(
            new: seeded, pending: [starredFeed: [starredStory(30, event: "known"), starredStory(31)]],
            delivery: delivery
        ).banners.filter { $0.lane == .starred }
        expectEqual(mixed.first?.count, 2, "N counts the announced event's story as well")
        expectEqual(mixed.first?.headlines.first, "Starred 31", "Headlines prefer the unannounced story")
        delivery.ledger.announced = [:]

        // 9. Priority lane: exceptional news, the highest lane, coalesced in bursts and never silenced.
        expectTrue(
            NotificationService.isPriority(title: "Earthquake kills hundreds", score: 0.8, publishers: 4),
            "A full-weight signal, a high score and four publishers are priority")
        expectFalse(
            NotificationService.isPriority(title: "Earthquake kills hundreds", score: 0.8, publishers: 3),
            "Three publishers are not enough")
        expectFalse(
            NotificationService.isPriority(title: "President announces a fund", score: 0.9, publishers: 6),
            "Half-weight words never make priority")
        var majors: [(article: FeedArticle, score: Double)] = []
        for index in 0..<5 {
            let article = report(700 + index, "Explosion \(index)")
            delivery.events[article.id] = "major-\(index)"
            delivery.publishers["major-\(index)"] = 5
            majors.append((article, 0.9 - Double(index) / 100))
        }
        var priority = NotificationService.plan(new: majors, pending: [:], delivery: delivery)
        expectEqual(
            priority.banners.map { $0.article?.title ?? NotificationService.groupedBody($0) },
            ["Explosion 0", "Explosion 1", "Explosion 2", "2 more major stories\nExplosion 3\nExplosion 4"],
            "A priority burst posts three banners, then one grouped banner")
        expectTrue(priority.banners.allSatisfy { $0.lane == .priority && $0.sound }, "Priority banners sound")
        delivery.ledger.priorityLastHalfHour = 3
        delivery.ledger.priorityGroupLastHalfHour = true
        priority = NotificationService.plan(new: majors, pending: [:], delivery: delivery)
        expectTrue(priority.banners.isEmpty, "Past both limits nothing posts now")
        expectEqual(priority.queued.map(\.event), (0..<5).map { "major-\($0)" }, "Every key waits; none is silenced")
        delivery.ledger.priorityGroupLastHalfHour = false
        delivery.ledger.priorityQueue = priority.queued
        priority = NotificationService.plan(new: [], pending: [:], delivery: delivery)
        expectEqual(priority.banners.map(\.count), [5], "The waiting keys arrive in the next grouped banner")
        expectEqual(
            Set(priority.banners.first.map { Array($0.announces.keys) } ?? []),
            Set((0..<5).map { "major-\($0)" } + (priority.banners.first?.members ?? [])),
            "The grouped banner announces every waiting key and each key's own report (#790)")
        delivery.ledger.priorityLastHalfHour = 0
        delivery.ledger.priorityQueue = []

        // A higher lane wins: an event that is priority and has a starred report posts one priority banner.
        var starredMajor = majors[0].article
        starredMajor.identityFeedURL = starredFeed
        delivery.events[starredMajor.id] = "major-0"
        let both = NotificationService.plan(
            new: [majors[0], (starredMajor, 0.3)], pending: [starredFeed: [(starredMajor, 0.3)]], delivery: delivery)
        expectEqual(
            both.banners.map(\.lane), [.priority], "The same event qualifying twice posts once, in the higher lane")
        let together = NotificationService.plan(
            new: seeded + [majors[1]], pending: [starredFeed: [starredStory(40), starredStory(41)]], delivery: delivery)
        expectEqual(
            together.banners.map(\.lane), [.priority, .starred, .normal, .normal, .normal],
            "Simultaneous arrivals post priority, then the starred group, then normal stories")

        // Two events of one story (#740): one banner per pass, threaded by the story; a later event of an announced
        // story adds to it without notifying again, unless it reaches a higher lane.
        var storyDelivery = NotificationDelivery(mode: .full)
        let stormFirst = report(800, "Storm reaches the coast")
        let stormSecond = report(801, "Storm leaves thousands without power")
        let stormMajor = report(802, "Explosion at a storm shelter")
        storyDelivery.events = [stormFirst.id: "storm-a", stormSecond.id: "storm-b", stormMajor.id: "storm-c"]
        storyDelivery.stories = ["storm-b": "storm-a", "storm-c": "storm-a"]
        storyDelivery.publishers = ["storm-c": 5]
        let storyPass = NotificationService.plan(
            new: [(stormFirst, 0.7), (stormSecond, 0.75)], pending: [:], delivery: storyDelivery
        ).banners
        expectEqual(
            storyPass.map { $0.article?.title ?? "" }, ["Storm leaves thousands without power"],
            "Two events of one story post one banner, by the stronger report")
        expectEqual(storyPass.first?.thread, "storm-a", "A story's banners share the story's thread")
        storyDelivery.ledger.announced["storm-a"] = .init(
            leadKey: EventFeedSummary.titleKey(stormFirst.title), lane: .normal)
        expectTrue(
            NotificationService.plan(new: [(stormSecond, 0.75)], pending: [:], delivery: storyDelivery).banners
                .isEmpty,
            "A new event of an announced story does not notify again")
        expectEqual(
            NotificationService.plan(new: [(stormMajor, 0.9)], pending: [:], delivery: storyDelivery).banners.map(
                \.lane), [.priority],
            "A new event of an announced story notifies when it reaches a higher lane")
        // Both events announced: the stronger one unchanged, the other with a new lead headline. The new lead posts.
        var bothAnnounced = storyDelivery
        bothAnnounced.ledger.announced["storm-b"] = .init(leadKey: "an older lead", lane: .normal)
        bothAnnounced.ledger.announced["storm-a"] = .init(
            leadKey: EventFeedSummary.titleKey(stormFirst.title), lane: .normal)
        expectEqual(
            NotificationService.plan(
                new: [(stormFirst, 0.8), (stormSecond, 0.75)], pending: [:], delivery: bothAnnounced
            ).banners.map { $0.article?.title ?? "" }, ["Storm leaves thousands without power"],
            "An unchanged event of a story does not hide the other event's new lead")
        // A waiting priority key of the story drops out when another of its events gets a banner this pass.
        var queuedStory = NotificationDelivery(mode: .full)
        let shelterBlast = report(803, "Explosion at a storm shelter kills four")
        queuedStory.events = [shelterBlast.id: "storm-c"]
        queuedStory.stories = ["storm-b": "storm-a", "storm-c": "storm-a"]
        queuedStory.publishers = ["storm-c": 5]
        queuedStory.ledger.priorityQueue = [
            QueuedPriority(event: "storm-b", title: "Storm leaves thousands without power", score: 0.8, leadKey: "x")
        ]
        let queuedPass = NotificationService.plan(new: [(shelterBlast, 0.9)], pending: [:], delivery: queuedStory)
        expectEqual(
            queuedPass.banners.map(\.grouped), [false],
            "A story's waiting key is covered by its new individual banner, not grouped beside it")
        // Two waiting keys of one story, left by earlier passes, count once in the next grouped banner.
        var twoQueued = NotificationDelivery(mode: .full)
        twoQueued.stories = ["storm-b": "storm-a", "storm-c": "storm-a"]
        twoQueued.ledger.priorityQueue = [
            QueuedPriority(event: "storm-c", title: "Explosion at a storm shelter", score: 0.9, leadKey: "c"),
            QueuedPriority(event: "storm-b", title: "Storm leaves thousands without power", score: 0.8, leadKey: "b"),
            QueuedPriority(event: "quake", title: "Earthquake strikes the north", score: 0.85, leadKey: "q"),
        ]
        let groupedOnce = NotificationService.plan(new: [], pending: [:], delivery: twoQueued).banners
        expectEqual(groupedOnce.map(\.count), [2], "A story queued twice counts once in the grouped banner")
        expectEqual(
            Set(groupedOnce.first.map { Array($0.announces.keys) } ?? []), ["storm-b", "storm-c", "quake"],
            "The grouped banner still announces every waiting key")
        // A waiting key whose own event was announced under another lead still posts after a priority announcement.
        twoQueued.ledger.priorityQueue = [
            QueuedPriority(event: "storm-b", title: "Storm death toll rises", score: 0.8, leadKey: "new lead")
        ]
        twoQueued.ledger.announced["storm-b"] = .init(leadKey: "old lead", lane: .priority)
        expectEqual(
            NotificationService.plan(new: [], pending: [:], delivery: twoQueued).banners.map(\.count), [1],
            "A waiting key with a changed lead survives the story's priority announcement")
        // An event announced in the normal lane whose story another event announced in priority does not post again
        // in the starred lane without a new lead.
        var laneDelivery = NotificationDelivery(mode: .full)
        var starredStorm = stormFirst
        starredStorm.identityFeedURL = "https://starred.invalid/feed"
        laneDelivery.starredFeedURLs = ["https://starred.invalid/feed"]
        laneDelivery.events = [starredStorm.id: "storm-a"]
        laneDelivery.stories = ["storm-c": "storm-a"]
        laneDelivery.ledger.announced = [
            "storm-a": .init(leadKey: EventFeedSummary.titleKey(stormFirst.title), lane: .normal),
            "storm-c": .init(leadKey: "c", lane: .priority),
        ]
        expectTrue(
            NotificationService.plan(
                new: [(starredStorm, 0.5)], pending: ["https://starred.invalid/feed": [(starredStorm, 0.5)]],
                delivery: laneDelivery
            ).banners.isEmpty,
            "A story announced in priority does not post again in the starred lane")
        // A stale starred event does not hide a fresh normal event of the same story.
        var staleStarred = NotificationDelivery(mode: .full)
        staleStarred.starredFeedURLs = ["https://starred.invalid/feed"]
        staleStarred.events = [starredStorm.id: "storm-a", stormSecond.id: "storm-b"]
        staleStarred.stories = ["storm-b": "storm-a"]
        staleStarred.ledger.announced = [
            "storm-a": .init(leadKey: EventFeedSummary.titleKey(stormFirst.title), lane: .starred),
            "storm-b": .init(leadKey: "an older lead", lane: .normal),
        ]
        expectEqual(
            NotificationService.plan(
                new: [(starredStorm, 0.5), (stormSecond, 0.75)],
                pending: ["https://starred.invalid/feed": [(starredStorm, 0.5)]], delivery: staleStarred
            ).banners.map { $0.article?.title ?? "" }, ["Storm leaves thousands without power"],
            "A fresh normal event posts beside a stale starred sibling")
        // A stale priority event does not hide a fresh normal event of the same story.
        var stalePriority = NotificationDelivery(mode: .full)
        stalePriority.events = [stormMajor.id: "storm-c", stormSecond.id: "storm-b"]
        stalePriority.stories = ["storm-b": "storm-a", "storm-c": "storm-a"]
        stalePriority.publishers = ["storm-c": 5]
        stalePriority.ledger.announced = [
            "storm-c": .init(leadKey: EventFeedSummary.titleKey(stormMajor.title), lane: .priority),
            "storm-b": .init(leadKey: "an older lead", lane: .normal),
        ]
        expectEqual(
            NotificationService.plan(
                new: [(stormMajor, 0.9), (stormSecond, 0.75)], pending: [:], delivery: stalePriority
            ).banners.map { $0.article?.title ?? "" }, ["Storm leaves thousands without power"],
            "A fresh normal event posts beside a stale priority sibling with a new lead")

        // Three publishers on arrival give a normal banner; a fourth makes it priority once, and never a third time.
        let rising = report(800, "Explosion levels block")
        delivery.events[rising.id] = "rising"
        delivery.publishers["rising"] = 3
        delivery.leadTitles["rising"] = rising.title
        let first = NotificationService.plan(new: [(rising, 0.9)], pending: [:], delivery: delivery).banners
        expectEqual(first.map(\.lane), [.normal], "Three publishers: a normal banner")
        let lead = EventFeedSummary.titleKey(rising.title)
        delivery.ledger.announced["rising"] = .init(leadKey: lead, lane: .normal)
        delivery.publishers["rising"] = 4
        let follow = report(801, "Explosion toll rises")
        delivery.events[follow.id] = "rising"
        expectEqual(
            NotificationService.plan(new: [(follow, 0.9)], pending: [:], delivery: delivery).banners.map(\.lane),
            [.priority], "The fourth publisher raises the event to one priority banner")
        delivery.ledger.announced["rising"]?.lane = .priority
        let later = report(802, "Explosion inquiry")
        delivery.events[later.id] = "rising"
        expectTrue(
            NotificationService.plan(new: [(later, 0.9)], pending: [:], delivery: delivery).banners.isEmpty,
            "An event announced as priority never posts a third banner")

        // Storage (#545, #665): the ledger reads what was recorded, keeps the highest lane, clamps a clock set back and
        // prunes old rows.
        do {
            let db = DatabaseEngine(path: ":memory:")
            try await db.open()
            let opener = report(300, "Lead report opens the event")
            let joiner = report(301, "Later report joins the event")
            try await db.upsertArticles([opener, joiner])
            let event = try await db.createEvent(memberArticleIDs: [opener.id])
            _ = try await db.addArticles([joiner.id], toEvent: event.id)
            expectEqual(
                try await db.eventLeadTitles([event.id]), [event.id: opener.title],
                "The lead story is the one that opened the event, not the newest member")
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let key = EventFeedSummary.titleKey(opener.title)
            try await db.recordNotification(
                PlannedBanner(
                    lane: .priority, grouped: false, thread: event.id, sound: true, announces: [event.id: key]),
                at: now)
            try await db.recordNotification(
                PlannedBanner(
                    lane: .normal, grouped: false, thread: event.id, sound: false, announces: [event.id: key]),
                at: now)
            try await db.recordNotification(
                PlannedBanner(lane: .starred, grouped: true, count: 4, feedURL: starredFeed, thread: "s", sound: false),
                at: now)
            try await db.queuePriority(
                [QueuedPriority(event: "waiting", title: "W", score: 0.8, leadKey: "w")], at: now)
            var ledger = try await db.notificationLedger(now: now.addingTimeInterval(60))
            expectEqual(ledger.announced[event.id], .init(leadKey: key, lane: .priority), "The highest lane is kept")
            expectEqual(ledger.normalLastHour, 1, "Normal banners count in the rolling hour")
            expectEqual(ledger.priorityLastHalfHour, 1, "Individual priority banners count in the half hour")
            expectEqual(ledger.lastStarred[starredFeed], now, "The feed's last starred banner is kept")
            expectEqual(ledger.priorityQueue.map(\.event), ["waiting"], "Waiting priority keys are read back")
            ledger = try await db.notificationLedger(now: now.addingTimeInterval(3601))
            expectEqual(ledger.normalLastHour, 0, "The hour rolls")
            ledger = try await db.notificationLedger(now: now.addingTimeInterval(-7200))
            expectEqual(ledger.normalLastHour, 1, "A clock set back clamps the later rows to now")
            ledger = try await db.notificationLedger(now: now.addingTimeInterval(-7200 + 3601))
            expectEqual(ledger.normalLastHour, 0, "So the window lasts at most its length from the change")
            ledger = try await db.notificationLedger(now: now.addingTimeInterval(2 * 86400))
            expectTrue(
                ledger.announced.isEmpty && ledger.priorityQueue.isEmpty, "A day later nothing is announced or waiting")
            try await db.recordNotification(
                PlannedBanner(lane: .normal, grouped: false, thread: "x", sound: false),
                at: now.addingTimeInterval(8 * 86400))
            ledger = try await db.notificationLedger(now: now.addingTimeInterval(8 * 86400))
            expectTrue(ledger.lastStarred.isEmpty, "Rows older than a week are pruned")
            await db.close()
        } catch {
            expectTrue(false, "Notification delivery storage failed: \(error)")
        }

        // Settings › Notifications › Send Test Notification (#926): a random story with a photo, and a status line
        // that names the reason nothing showed.
        let plain = FeedArticle(
            title: "No photo", link: "https://example.com/plain", guid: "sample-plain", description: "Summary",
            pubDate: Date(), source: "Publisher")
        let photo = FeedArticle(
            title: "Photo", link: "https://example.com/photo", guid: "sample-photo", description: "Summary",
            pubDate: Date(), source: "Publisher", imageUrl: "https://example.com/photo.jpg")
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<10 {
            expectEqual(
                NotificationService.sampleStory(from: [plain, photo, plain], using: &generator)?.id, photo.id,
                "The test banner prefers a story with a photo")
        }
        expectEqual(
            NotificationService.sampleStory(from: [plain], using: &generator)?.id, plain.id,
            "Without any photo, any story serves as the test banner")
        expectTrue(NotificationService.sampleStory(from: []) == nil, "No stories, no test banner")
        func status(
            _ outcome: NotificationService.PostOutcome, authorization: UNAuthorizationStatus = .authorized,
            alert: UNNotificationSetting = .enabled, style: UNAlertStyle = .banner,
            previews: UNShowPreviewsSetting = .always
        ) -> String {
            NotificationService.sampleStatus(
                outcome, authorization: authorization, alert: alert, style: style, previews: previews)
        }
        expectTrue(status(.halted).hasPrefix("Not shown:"), "A halted test names the mode setting")
        expectTrue(
            status(.failed(domain: "Other", code: 7)).contains("Other 7"),
            "A banner that cannot draw shows domain and code")
        expectTrue(
            status(.suppressed(.notAuthorized), authorization: .denied).contains("turned off"),
            "Denied permission is named")
        expectTrue(
            status(.suppressed(.notAuthorized), authorization: .notDetermined).contains("not asked"),
            "Permission not yet asked is named")
        expectTrue(status(.suppressed(.styleNone), style: .none).contains("None"), "Alert style None is named")
        expectTrue(
            status(.suppressed(.alertsOff), alert: .disabled).contains("alerts for News are off"), "Alerts off is named"
        )
        expectTrue(status(.suppressed(.focus)).contains("Focus"), "A Focus is named")
        expectTrue(status(.posted, previews: .never).contains("story hidden"), "Hidden previews are named")
        expectTrue(
            status(.posted, style: .alert).contains("until you close it"), "The Alerts style is named after a banner")
        expectEqual(status(.posted), "Shown.", "A plain success says so")
    }

    /// #1201: a pass plans its banners from the stories as triage saw them and posts minutes later. A story from a feed
    /// without images, or whose feed image is a logo, posts with the photo the page lookup recorded in the library,
    /// the way FeedManager wires `curated`; a story with a photo of its own keeps it.
    @MainActor
    static func testBannerTakesRecordedPhoto() async throws {
        print("  - Testing a banner posts the photo the page lookup recorded (#1201)...")
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        func story(_ id: String, image: String?) -> FeedArticle {
            FeedArticle(
                storedID: id, title: "Explosion at a refinery in Houston, dozens killed; urgent evacuation",
                link: "https://photo.invalid/\(id)", guid: id, description: "", pubDate: Date(),
                source: "Publisher \(id)", imageUrl: image)
        }
        let bare = story("bare", image: nil)
        let logo = story("branded", image: "https://photo.invalid/static/logo.png")
        let own = story("own", image: "https://photo.invalid/own/lead.jpg")
        _ = try await db.upsertArticles([bare, logo, own])
        for item in [bare, logo, own] {
            _ = try await db.recordStoryImage(item.id, imageURL: "https://cdn.invalid/\(item.id)/found.jpg")
        }
        actor Recorder {
            var images: [String: [URL]] = [:]
            func record(_ banner: StoryBanner) { images[banner.articleID ?? ""] = banner.imageURLs }
        }
        let recorder = Recorder()
        let service = NotificationService(post: { await recorder.record($0) }, spacing: .zero)
        for item in [bare, logo, own] {
            var delivery = NotificationDelivery(mode: .full)
            delivery.curated = { story in (try? await db.curateImages(in: [story]))?.first ?? story }
            await service.triageAndNotify(newArticles: [item], delivery: delivery)
        }
        let images = await recorder.images
        expectEqual(
            images[bare.id]?.first?.absoluteString, "https://cdn.invalid/bare/found.jpg",
            "A story its feed gave no image posts with the recorded photo")
        expectEqual(
            images[logo.id]?.first?.absoluteString, "https://cdn.invalid/branded/found.jpg",
            "A story whose feed image is a logo posts with the recorded photo")
        expectEqual(
            images[own.id]?.first?.absoluteString, own.imageUrl, "A story with a photo of its own keeps it")
        await db.close()
    }

    @MainActor
    static func testFirstBannerWaitsForPageImage() async throws {
        let suite = testDefaultsSuite("test.banner.first-photo")
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaults(suite) }
        let settings = AppSettings(defaults: defaults)
        let feed = "https://photo.invalid/feed"
        settings.feedURLs = [feed]
        settings.aiEnabled = false
        settings.notificationsEnabled = true
        settings.notificationMode = .full
        let story = FeedArticle(
            storedID: "first-photo", title: "Explosion at a refinery in Houston, dozens killed; urgent evacuation",
            link: "https://photo.invalid/first-photo", guid: "first-photo", description: "", pubDate: Date(),
            source: "Publisher")
        actor Gate {
            var isOpen = false
            var waiting: CheckedContinuation<Void, Never>?
            var calls = 0
            func open() {
                isOpen = true
                waiting?.resume()
                waiting = nil
            }
            func find() async -> StoryImageLookup {
                calls += 1
                if !isOpen { await withCheckedContinuation { waiting = $0 } }
                return .found("https://cdn.invalid/first-photo.jpg")
            }
        }
        actor Recorder {
            var banners: [StoryBanner] = []
            func post(_ banner: StoryBanner) { banners.append(banner) }
        }
        let gate = Gate()
        let recorder = Recorder()
        let service = NotificationService(post: { await recorder.post($0) }, spacing: .zero)
        let store = ArticleStore(database: DatabaseEngine(path: ":memory:"), spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        let manager = FeedManager(
            settings: settings, store: store, schedulesRefresh: false,
            fetchBatch: { urls, _ in urls.map { ($0, [story], nil, nil) } },
            notifyBatch: { articles, delivery in
                var delivery = delivery
                let curated = delivery.curated
                delivery.curated = { story in
                    let result = await curated(story)
                    await gate.open()
                    return result
                }
                await service.triageAndNotify(newArticles: articles, delivery: delivery)
            },
            dependencies: FeedManager.Dependencies(
                imageFinder: StoryImageFinder { _ in await gate.find() }, allowsBackgroundWork: { true }))
        await manager.fetchFeedsAsync()
        await manager.notificationPass?.value
        let banners = await recorder.banners
        expectEqual(
            banners.first?.imageURLs.first?.absoluteString, "https://cdn.invalid/first-photo.jpg",
            "The first banner includes the photo saved while its page lookup is running")
        expectEqual(await gate.calls, 1, "The page is requested only once")
        manager.stopBackgroundWork()
        await store.database.close()
    }

    @MainActor
    static func testBannerPriorityAcrossLookupReplacement() async throws {
        let suite = testDefaultsSuite("test.banner.priority-replacement")
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaults(suite) }
        let settings = AppSettings(defaults: defaults)
        let feed = "https://photo.invalid/feed"
        settings.feedURLs = [feed]
        settings.aiEnabled = false
        settings.notificationsEnabled = true
        settings.notificationMode = .full
        let first = FeedArticle(
            storedID: "old", title: "Garden", link: "https://photo.invalid/old",
            guid: "old", description: "", pubDate: Date(), source: "Publisher")
        let selected = FeedArticle(
            storedID: "selected", title: "Explosion at a refinery in Houston, dozens killed; urgent evacuation",
            link: "https://photo.invalid/selected", guid: "selected", description: "", pubDate: Date(),
            source: "Publisher")
        actor Gate {
            var calls: [String] = []
            var oldActive = false
            var overlapped = false
            var started: CheckedContinuation<Void, Never>?
            var release: CheckedContinuation<Void, Never>?
            func wait() async { if calls.isEmpty { await withCheckedContinuation { started = $0 } } }
            func open() {
                release?.resume()
                release = nil
            }
            func find(_ link: String) async -> StoryImageLookup {
                calls.append(link)
                if link.hasSuffix("/old") {
                    oldActive = true
                    started?.resume()
                    started = nil
                    await withCheckedContinuation { release = $0 }
                    oldActive = false
                    return .unreachable
                }
                if oldActive { overlapped = true }
                return .found("https://cdn.invalid/selected.jpg")
            }
        }
        actor Recorder {
            var banners: [StoryBanner] = []
            func post(_ banner: StoryBanner) { banners.append(banner) }
        }
        let gate = Gate()
        let recorder = Recorder()
        let service = NotificationService(post: { await recorder.post($0) }, spacing: .zero)
        let store = ArticleStore(database: DatabaseEngine(path: ":memory:"), spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        _ = try await store.database.upsertArticles([first])
        let manager = FeedManager(
            settings: settings, store: store, schedulesRefresh: false,
            fetchBatch: { urls, _ in urls.map { ($0, [selected], nil, nil) } },
            notifyBatch: { articles, delivery in
                var delivery = delivery
                let prioritize = delivery.prioritizeImage
                delivery.prioritizeImage = { id in
                    let accepted = await prioritize(id)
                    await gate.open()
                    return accepted
                }
                await service.triageAndNotify(newArticles: articles, delivery: delivery)
            },
            dependencies: FeedManager.Dependencies(
                imageFinder: StoryImageFinder { link in await gate.find(link) }, allowsBackgroundWork: { true }))
        manager.requestStoryImages(for: [first.id])
        await gate.wait()
        await manager.fetchFeedsAsync()
        await manager.notificationPass?.value
        expectEqual(
            await recorder.banners.first?.imageURLs.first?.absoluteString, "https://cdn.invalid/selected.jpg",
            "The banner's story is prioritized after the old worker stops")
        expectFalse(await gate.overlapped, "The replacement does not overlap the cancelled finder")
        let calls = await gate.calls
        expectEqual(
            calls.prefix(2).map { $0 }, [first.link, selected.link],
            "The successor waits and requests the banner story first")
        manager.stopBackgroundWork()
        await store.database.close()
    }

    static func testFirstIndividualBannerAfterGroupedWaitsForPhoto() async {
        let starredFeed = "https://starred.invalid/feed"
        let pending = (1...2).map { index in
            FeedArticle(
                storedID: "starred-\(index)", title: "Garden notes \(index)",
                link: "https://starred.invalid/\(index)", guid: "starred-\(index)", description: "", pubDate: Date(),
                source: "Starred")
        }
        let story = FeedArticle(
            storedID: "after-group", title: "Explosion at a refinery in Houston, dozens killed; urgent evacuation",
            link: "https://photo.invalid/after-group", guid: "after-group", description: "", pubDate: Date(),
            source: "Publisher")
        actor State {
            var banners: [StoryBanner] = []
            var requested: [String] = []
            func post(_ banner: StoryBanner) { banners.append(banner) }
            func request(_ id: String) { requested.append(id) }
        }
        let state = State()
        let service = NotificationService(post: { await state.post($0) }, spacing: .zero)
        var delivery = NotificationDelivery(mode: .full)
        delivery.starredFeedURLs = [starredFeed]
        delivery.starredPending = [starredFeed: pending]
        delivery.prioritizeImage = { id in
            await state.request(id)
            return false
        }
        await service.triageAndNotify(newArticles: [story], delivery: delivery)
        expectEqual(await state.banners.count, 2, "The grouped starred banner and the story's banner both post")
        expectEqual(
            await state.requested, [story.id],
            "The first individual banner asks for its photo although a grouped banner posts before it")
    }

    static func testBannerImageWaitTimeoutAndCancellation() async {
        let story = FeedArticle(
            storedID: "wait-timeout", title: "Explosion at a refinery in Houston, dozens killed; urgent evacuation",
            link: "https://photo.invalid/wait-timeout", guid: "wait-timeout", description: "", pubDate: Date(),
            source: "Publisher")
        actor State {
            var banners: [StoryBanner] = []
            var waiting: CheckedContinuation<Void, Never>?
            var started = false
            var checks = 0
            func modeContinues() -> Bool {
                checks += 1
                return checks != 2
            }
            func post(_ banner: StoryBanner) { banners.append(banner) }
            func signal() {
                started = true
                waiting?.resume()
                waiting = nil
            }
            func wait() async { if !started { await withCheckedContinuation { waiting = $0 } } }
        }
        actor Requests {
            var count = 0
            func record() { count += 1 }
        }
        let requests = Requests()
        var pictured = story
        pictured.imageUrl = "https://cdn.invalid/existing.jpg"
        var picturedDelivery = NotificationDelivery(mode: .full)
        picturedDelivery.prioritizeImage = { _ in
            await requests.record()
            return true
        }
        let immediate = State()
        let picturedService = NotificationService(post: { await immediate.post($0) }, spacing: .zero)
        await picturedService.triageAndNotify(newArticles: [pictured], delivery: picturedDelivery)
        expectEqual(await requests.count, 0, "A story with a usable photo never waits for a lookup")
        expectEqual(
            await immediate.banners.first?.imageURLs.first?.absoluteString, pictured.imageUrl,
            "A story's own photo is posted immediately")

        let timeout = State()
        let service = NotificationService(post: { await timeout.post($0) }, spacing: .zero)
        var delivery = NotificationDelivery(mode: .full)
        delivery.prioritizeImage = { _ in true }
        let start = ContinuousClock.now
        await service.triageAndNotify(newArticles: [story], delivery: delivery)
        let elapsed = start.duration(to: .now)
        expectTrue(elapsed >= .seconds(2), "A missing image has a short opportunity to arrive")
        expectTrue(elapsed < .seconds(5), "A missing image does not hold the banner indefinitely")
        expectEqual(await timeout.banners.count, 1, "The banner posts when the image wait expires")

        let disabledRequests = Requests()
        let disabled = State()
        let disabledService = NotificationService(post: { await disabled.post($0) }, spacing: .zero)
        var disabledDelivery = NotificationDelivery(mode: .full)
        disabledDelivery.continues = { false }
        disabledDelivery.prioritizeImage = { _ in
            await disabledRequests.record()
            return true
        }
        await disabledService.triageAndNotify(newArticles: [story], delivery: disabledDelivery)
        expectEqual(await disabledRequests.count, 0, "A disabled pass starts no targeted lookup")
        expectTrue(await disabled.banners.isEmpty, "A disabled pass posts no banner")

        let switched = State()
        let switchedService = NotificationService(post: { await switched.post($0) }, spacing: .zero)
        var switchedDelivery = NotificationDelivery(mode: .full)
        switchedDelivery.prioritizeImage = { _ in true }
        switchedDelivery.continues = { await switched.modeContinues() }
        await switchedService.triageAndNotify(newArticles: [story], delivery: switchedDelivery)
        expectEqual(await switched.checks, 2, "A mode change ends the pass without checking again")
        expectTrue(await switched.banners.isEmpty, "A pass halted during the image wait never posts")

        let cancelled = State()
        let cancellable = NotificationService(post: { await cancelled.post($0) }, spacing: .zero)
        var cancelDelivery = NotificationDelivery(mode: .full)
        cancelDelivery.prioritizeImage = { _ in
            await cancelled.signal()
            return true
        }
        let preparedDelivery = cancelDelivery
        let task = Task { await cancellable.triageAndNotify(newArticles: [story], delivery: preparedDelivery) }
        await cancelled.wait()
        task.cancel()
        await task.value
        expectTrue(await cancelled.banners.isEmpty, "Cancelling an image wait drops the banner")
    }

    static func testPriorityImageLookupSurvivesCancellation() async throws {
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        let story = FeedArticle(
            storedID: "priority", title: "Story", link: "https://photo.invalid/priority", guid: "priority",
            description: "", pubDate: Date(), source: "Publisher")
        _ = try await db.upsertArticles([story])
        actor Gate {
            var started = false
            var startedWaiter: CheckedContinuation<Void, Never>?
            var release: CheckedContinuation<Void, Never>?
            func wait() async { if !started { await withCheckedContinuation { startedWaiter = $0 } } }
            func open() {
                release?.resume()
                release = nil
            }
            func find() async -> StoryImageLookup {
                started = true
                startedWaiter?.resume()
                startedWaiter = nil
                await withCheckedContinuation { release = $0 }
                return .unreachable
            }
        }
        let gate = Gate()
        let priority = StoryImagePriority()
        await priority.request(story.id)
        let task = Task {
            try await StoryCurator.run(
                in: db, imageFinder: StoryImageFinder { _ in await gate.find() }, priority: priority)
        }
        await gate.wait()
        task.cancel()
        await gate.open()
        _ = try? await task.value
        expectTrue(await priority.hasPending, "A cancelled priority remains for the successor")
        _ = try await StoryCurator.run(
            in: db, imageFinder: StoryImageFinder { _ in .found("https://cdn.invalid/priority.jpg") },
            priority: priority)
        expectEqual(
            try await db.storyImages(for: [story.id])[story.id], "https://cdn.invalid/priority.jpg",
            "The successor retries the cancelled priority")
        await priority.request("not-in-library")
        _ = try await StoryCurator.run(in: db, imageFinder: StoryImageFinder { _ in .none }, priority: priority)
        expectFalse(await priority.hasPending, "An ineligible priority does not schedule endless empty passes")
        let abandoned = FeedArticle(
            storedID: "abandoned", title: "Another story", link: "https://photo.invalid/abandoned", guid: "abandoned",
            description: "", pubDate: Date(), source: "Another publisher")
        _ = try await db.upsertArticles([abandoned])
        let secondGate = Gate()
        await priority.request(abandoned.id)
        let abandonedTask = Task {
            try await StoryCurator.run(
                in: db, imageFinder: StoryImageFinder { _ in await secondGate.find() }, priority: priority)
        }
        await secondGate.wait()
        await priority.withdraw(abandoned.id)
        abandonedTask.cancel()
        await secondGate.open()
        _ = try? await abandonedTask.value
        expectFalse(await priority.hasPending, "A withdrawn in-flight priority is not requeued on cancellation")
        await db.close()
    }

    @MainActor
    static func testImageLookupDatabaseFailureDoesNotSpin() async throws {
        let suite = testDefaultsSuite("test.banner.image-database-failure")
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaults(suite) }
        let settings = AppSettings(defaults: defaults)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(
            "image-failure-\(UUID().uuidString).sqlite3"
        ).path
        defer { removeTemporaryLibrary(atPath: path) }
        let store = ArticleStore(database: DatabaseEngine(path: path), spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        let story = FeedArticle(
            storedID: "retry", title: "Story", link: "https://photo.invalid/retry", guid: "retry",
            description: "", pubDate: Date(), source: "Publisher")
        _ = try await store.database.upsertArticles([story])
        await store.database.close()
        let manager = FeedManager(
            settings: settings, store: store, schedulesRefresh: false,
            dependencies: FeedManager.Dependencies(
                imageFinder: StoryImageFinder { _ in .found("https://cdn.invalid/retry.jpg") },
                allowsBackgroundWork: { true }))
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await manager.prioritizeBannerImage(story.id)
        }
        expectFalse(await cancelled.value, "A cancelled request does not start a lookup")
        expectFalse(await manager.imagePriority.hasPending, "A cancelled request leaves no priority behind")
        expectTrue(manager.imageLookupTask == nil, "A cancelled request starts no worker")
        expectTrue(await manager.prioritizeBannerImage(story.id), "The first request starts a lookup")
        await manager.imageLookupTask?.value
        expectTrue(manager.imageLookupTask == nil, "A database failure leaves no successor running")
        expectTrue(await manager.imagePriority.hasPending, "The failed priority remains queued")
        try await store.database.open()
        expectTrue(await manager.prioritizeBannerImage(story.id), "A later request starts a new pass")
        await manager.imageLookupTask?.value
        expectEqual(
            try await store.database.storyImages(for: [story.id])[story.id], "https://cdn.invalid/retry.jpg",
            "The later pass handles the retained request")
        manager.stopBackgroundWork()
        await store.database.close()
    }

    /// #790: a banner for a report outside any event records the report itself. When another outlet's report later
    /// clusters with it, the event counts as announced, so the new report posts no second banner on another thread.
    @MainActor
    static func testNotifyBeforeClustering() async throws {
        print("  - Testing a report notified before clustering announces its later event (#790)...")
        let db = DatabaseEngine(path: ":memory:")
        try await db.open()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func report(_ id: String, _ title: String, hoursAgo: Double, source: String) -> FeedArticle {
            FeedArticle(
                storedID: id, title: title, link: "https://notify.invalid/\(id)", guid: id, description: "",
                pubDate: now.addingTimeInterval(-hoursAgo * 3600), source: source)
        }
        let first = report("n790-a", "Breaking: Mosul dam failure, emergency declared", hoursAgo: 2, source: "Wire One")
        let second = report(
            "n790-b", "Breaking: Mosul dam bursts, emergency declared", hoursAgo: 1, source: "Daily Two")
        _ = try await db.upsertArticles([first, second])

        let alone = NotificationService.plan(
            new: [(article: first, score: 0.9)], pending: [:],
            delivery: NotificationDelivery(mode: .full, now: now, ledger: try await db.notificationLedger(now: now)))
        expectEqual(alone.banners.count, 1, "The report alone posts a banner")
        expectEqual(
            alone.banners.first?.announces, [first.id: EventFeedSummary.titleKey(first.title)],
            "A report outside any event is announced under its own ID")
        for banner in alone.banners { try await db.recordNotification(banner, at: now) }
        var ledger = try await db.notificationLedger(now: now.addingTimeInterval(60))
        expectTrue(
            NotificationService.plan(
                new: [(article: first, score: 0.9)], pending: [:],
                delivery: NotificationDelivery(mode: .full, now: now.addingTimeInterval(60), ledger: ledger)
            ).banners.isEmpty, "The announced report alone does not post again")

        let event = try await db.createEvent(memberArticleIDs: [first.id, second.id], at: now)
        let later = now.addingTimeInterval(600)
        ledger = try await db.notificationLedger(now: later)
        let announced = NotificationLedger.Announcement(leadKey: EventFeedSummary.titleKey(first.title), lane: .normal)
        expectEqual(
            ledger.announced, [event.id: announced, first.id: announced],
            "The report's announcement is copied to the event it joined, under the event's lead headline, and kept")
        let clustered = NotificationService.plan(
            new: [(article: second, score: 0.9)], pending: [:],
            delivery: NotificationDelivery(
                mode: .full, events: [first.id: event.id, second.id: event.id], publishers: [event.id: 2],
                leadTitles: [event.id: first.title], now: later, ledger: ledger))
        expectTrue(clustered.banners.isEmpty, "The second outlet's report of the announced event posts no banner")

        // The report keeps its own row: separated into another event, it makes that event announced too.
        let third = report("n790-c", "Breaking: Mosul dam failure floods villages", hoursAgo: 0.5, source: "Post")
        _ = try await db.upsertArticles([third])
        _ = try await db.separateArticle(first.id, fromEvent: event.id)
        let moved = try await db.createEvent(memberArticleIDs: [first.id, third.id], at: later)
        ledger = try await db.notificationLedger(now: later.addingTimeInterval(60))
        expectEqual(
            ledger.announced[moved.id]?.lane, .normal, "The event the separated report joins inherits its announcement")
        let separated = NotificationService.plan(
            new: [(article: third, score: 0.9)], pending: [:],
            delivery: NotificationDelivery(
                mode: .full, events: [first.id: moved.id, third.id: moved.id], publishers: [moved.id: 2],
                leadTitles: [moved.id: first.title], now: later.addingTimeInterval(60), ledger: ledger))
        expectTrue(separated.banners.isEmpty, "The separated report's new event posts no duplicate banner")
        await db.close()
    }

    /// Notification lanes through `FeedManager` (#665): the normal limit rolls across refreshes and a relaunch, delivery
    /// never removes a story, starring a feed brings up no backlog, and a starred burst is one banner.
    @MainActor
    static func testNotificationLanesAcrossRefreshes(fixtureRoot: URL) async throws {
        print("  - Testing notification lanes across refreshes and relaunch...")
        // Three full-weight signal words and six named places: each is breaking, and alone it is never priority.
        let headlines = [
            "Breaking: earthquake in Tokyo, Osaka, Kyoto, Nagoya, Sapporo and Kobe; emergency declared",
            "Breaking: explosion in Houston, Dallas, Austin, Denver, Phoenix and Tucson; emergency declared",
            "Breaking: attack in Paris, Lyon, Marseille, Nice, Lille and Bordeaux; emergency declared",
            "Breaking: crisis in Lagos, Abuja, Kano, Ibadan, Accra and Lome; emergency declared",
            "Breaking: mayors arrested in Madrid, Seville, Valencia, Bilbao, Malaga and Zaragoza; emergency session",
            "Breaking: dozens killed in Lima, Quito, Bogota, Caracas, Santiago and Montevideo; emergency declared",
            "Breaking: minister resigns in Cairo, Alexandria, Giza, Luxor, Aswan and Suez; emergency session",
            "Breaking: cars recalled in Berlin, Munich, Hamburg, Cologne, Frankfurt and Stuttgart; emergency checks",
            "Breaking: governors indicted in Sydney, Melbourne, Brisbane, Perth, Adelaide and Hobart; emergency sitting",
        ]
        let start = Date()
        func story(_ id: String, _ title: String, source: String) -> FeedArticle {
            FeedArticle(
                title: title, link: fixtureRoot.appendingPathComponent("lanes/\(id)").absoluteString, guid: id,
                description: "", pubDate: start, source: source)
        }
        let loud = headlines.indices.map { story("loud-\($0)", headlines[$0], source: "Wire \($0)") }
        let plainFeed = fixtureRoot.appendingPathComponent("lanes-plain").absoluteString
        let starredFeed = fixtureRoot.appendingPathComponent("lanes-starred").absoluteString
        let suite = testDefaultsSuite("test.notification.lanes")
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaults(suite) }
        let settings = AppSettings(defaults: defaults)
        settings.feedURLs = [plainFeed, starredFeed]
        settings.aiEnabled = false
        settings.notificationsEnabled = true
        settings.notificationMode = .full
        struct Posted: Sendable {
            let title: String
            let body: String
            let thread: String
            let actions: Bool
        }
        actor Recorder {
            var posted: [Posted] = []
            func record(_ banner: StoryBanner) {
                posted.append(
                    Posted(title: banner.title, body: banner.body, thread: banner.thread, actions: banner.actions))
            }
        }
        let recorder = Recorder()
        let service = NotificationService(post: { await recorder.record($0) }, spacing: .zero)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("lanes-\(UUID().uuidString).sqlite3")
            .path
        defer { removeTemporaryLibrary(atPath: path) }
        var store = ArticleStore(database: DatabaseEngine(path: path), spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        // A refresh without a clock reads the real one at the pass, as the app does, after its stories are stored. It
        // returns the titles of the stories its banners covered (#584).
        @discardableResult
        func refresh(plain: [FeedArticle] = [], starred: [FeedArticle] = [], at clock: Date? = nil) async -> Set<String>
        {
            let manager = FeedManager(
                settings: settings, store: store, schedulesRefresh: false,
                fetchBatch: { urls, _ in urls.map { ($0, $0 == starredFeed ? starred : plain, nil, nil) } },
                notifyBatch: { articles, delivery in
                    await service.triageAndNotify(newArticles: articles, delivery: delivery)
                }, dependencies: FeedManager.Dependencies(imageFinder: .unavailable, now: { clock ?? Date() }))
            await manager.fetchFeedsAsync()
            // The pass runs on after the refresh returns; this waits for its banners before reading them.
            _ = await manager.notificationPass?.value
            manager.stopBackgroundWork()
            return Set(store.articles.filter { manager.notifiedStoryIDs.contains($0.id) }.map(\.title))
        }

        // The normal limit rolls: five of six post, a refresh 30 minutes later after a relaunch posts none, and one 61
        // minutes after the first posts again.
        let firstNotified = await refresh(plain: Array(loud.prefix(6)), at: start)
        expectEqual(await recorder.posted.count, 5, "Five normal banners in the first hour")
        expectEqual(firstNotified.count, 5, "The five posted stories count as notified, the sixth does not")
        expectTrue(firstNotified.isSubset(of: Set(headlines.prefix(6))), "Only this refresh's stories are notified")
        await store.database.close()
        store = ArticleStore(database: DatabaseEngine(path: path), spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        await refresh(plain: Array(loud[6...7]), at: start.addingTimeInterval(30 * 60))
        expectEqual(await recorder.posted.count, 5, "Thirty minutes later, after a relaunch, the hour is still full")
        await refresh(plain: [loud[8]], at: start.addingTimeInterval(61 * 60))
        expectEqual(await recorder.posted.count, 6, "Sixty-one minutes after the first banners, one posts again")
        let stored = Set(try await store.database.fetchArticles(limit: nil).map(\.title))
        expectTrue(Set(headlines).isSubset(of: stored), "Every story is stored, notified or not")
        expectTrue(
            Set(headlines).isSubset(of: Set(store.articles.map(\.title))), "Every story stays in the reader's feed")

        // Starring a feed brings up none of its backlog; its next new story notifies, and a burst 21 minutes later is
        // one grouped banner.
        let backlog = (0..<5).map {
            story("backlog-\($0)", "Starred column \($0) on garden design", source: "Starred Daily")
        }
        await refresh(starred: backlog)
        let before = await recorder.posted.count
        expectTrue(settings.setFeedStarred(starredFeed, true), "The feed is starred")
        await refresh(plain: [story("quiet", "Library extends opening hours", source: "Town Paper")])
        expectEqual(await recorder.posted.count, before, "Starring a feed posts nothing for its backlog")
        await refresh(
            starred: backlog + [story("fresh", "Starred column on winter bulbs", source: "Starred Daily")])
        let single = await recorder.posted.dropFirst(before)
        expectEqual(single.map(\.title), ["Starred Daily"], "The feed's first new story is one starred banner")
        expectEqual(
            single.map(\.actions), [true], "A starred story's banner has story actions")
        let burst = (0..<20).map { story("burst-\($0)", "Starred note \($0) about orchards", source: "Starred Daily") }
        let burstNotified = await refresh(starred: burst, at: Date().addingTimeInterval(21 * 60))
        expectEqual(burstNotified, Set(burst.map(\.title)), "A grouped banner's stories all count as notified")
        let grouped = await recorder.posted.dropFirst(before + 1)
        expectEqual(grouped.count, 1, "Twenty new starred stories are one banner: \(grouped.map(\.body))")
        expectEqual(grouped.first?.thread, "starred-\(starredFeed)", "The burst is threaded under the feed")
        expectTrue(
            grouped.first?.body.hasPrefix("20 new stories\n") == true,
            "The burst counts every story: \(grouped.first?.body ?? "")")
        expectEqual(grouped.first?.actions, false, "A grouped banner has no story actions")
        await store.database.close()
    }

    /// Cross-refresh dedupe through `FeedManager` (#545): the first refresh announces an event; a report that joins it
    /// in the next refresh posts no second banner; once the recorded lead headline differs, a new report notifies.
    @MainActor
    static func testNotificationDedupeAcrossRefreshes(fixtureRoot: URL) async throws {
        print("  - Testing notification dedupe across refreshes...")
        let now = Date()
        func report(_ id: String, _ title: String, hoursAgo: Double, source: String) -> FeedArticle {
            FeedArticle(
                title: title, link: fixtureRoot.appendingPathComponent("dedupe/\(id)").absoluteString, guid: id,
                description:
                    "The disaster agency AFAD said buildings collapsed in Malatya, Ankara and Istanbul after the earthquake struck eastern Turkey.",
                pubDate: now.addingTimeInterval(-hoursAgo * 3600), source: source)
        }
        // Three signal words and the named places make every report breaking, so only the dedupe keeps one quiet.
        let quake = [
            report(
                "d1", "Breaking: earthquake strikes Malatya in eastern Turkey, emergency declared", hoursAgo: 3,
                source: "Wire One"),
            report(
                "d2", "Breaking: Malatya earthquake, emergency declared as AFAD says buildings collapsed",
                hoursAgo: 2.5,
                source: "Daily Two"),
            report(
                "d3", "Breaking: rescuers search collapsed buildings after Malatya earthquake, emergency declared",
                hoursAgo: 2, source: "Herald Three"),
            report(
                "d4", "Breaking: eastern Turkey earthquake, emergency declared as buildings collapse in Malatya",
                hoursAgo: 1.5, source: "Courier Four"),
        ]
        let feeds = (1...4).map { fixtureRoot.appendingPathComponent("dedupe-feed-\($0)").absoluteString }
        let suite = testDefaultsSuite("test.notification.dedupe")
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaults(suite) }
        let settings = AppSettings(defaults: defaults)
        settings.feedURLs = feeds
        settings.aiEnabled = false
        settings.notificationsEnabled = true
        settings.notificationMode = .full
        let store = ArticleStore(database: DatabaseEngine(path: ":memory:"), spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        actor Recorder {
            var threads: [String] = []
            func record(_ thread: String) { threads.append(thread) }
        }
        let recorder = Recorder()
        let service = NotificationService(
            post: { await recorder.record($0.thread) }, spacing: .zero)
        // Each refresh is a manager over the same library whose feeds carry the first `count` reports, one per feed.
        func refresh(_ count: Int) async {
            let manager = FeedManager(
                settings: settings, store: store, schedulesRefresh: false,
                fetchBatch: { urls, _ in
                    urls.map { url in
                        let index = feeds.firstIndex(of: url) ?? count
                        return (url, index < count ? [quake[index]] : [], nil, nil)
                    }
                },
                notifyBatch: { articles, delivery in
                    await service.triageAndNotify(newArticles: articles, delivery: delivery)
                }, dependencies: FeedManager.Dependencies(imageFinder: .unavailable))
            await manager.fetchFeedsAsync()
            _ = await manager.notificationPass?.value
            manager.stopBackgroundWork()
        }

        await refresh(2)
        let first = await recorder.threads
        expectEqual(first.count, 1, "Two reports of one new event are one banner: \(first)")
        let ids = store.articles.map(\.id)
        let event = try await store.database.eventIDs(forArticles: ids)
        expectEqual(Set(event.values).count, 1, "The first refresh groups both reports into one event: \(event)")

        await refresh(3)
        let joined = try await store.database.eventIDs(forArticles: store.articles.map(\.id))
        expectEqual(Set(joined.values).count, 1, "The third report joins the announced event: \(joined)")
        expectEqual(await recorder.threads, first, "A report joining an event announced today posts no second banner")

        guard let announced = joined.values.first else { return }
        try await store.database.recordNotification(
            PlannedBanner(
                lane: .normal, grouped: false, thread: announced, sound: false,
                announces: [announced: EventFeedSummary.titleKey("An earlier lead headline")]), at: Date())
        await refresh(4)
        expectEqual(
            await recorder.threads, first + [announced], "A new report notifies once the lead headline changed")
        await store.database.close()

        // A merge never makes an announced story new again: the absorbed event's announcement and waiting priority key
        // move to the event it joined, keyed to that event's lead headline, so its next report stays quiet.
        let merges = DatabaseEngine(path: ":memory:")
        try await merges.open()
        let lead = report("m1", "Dam bursts near Mosul as floodwater reaches villages", hoursAgo: 4, source: "Wire One")
        let fragment = report("m2", "Breaking: Mosul dam failure, emergency declared", hoursAgo: 3, source: "Daily Two")
        let waiting = report("m3", "Breaking: Mosul flood toll rises, emergency declared", hoursAgo: 2, source: "Post")
        let later = report("m4", "Breaking: Mosul evacuations widen, emergency declared", hoursAgo: 1, source: "Times")
        _ = try await merges.upsertArticles([lead, fragment, waiting, later])
        let survivor = try await merges.createEvent(memberArticleIDs: [lead.id]).id
        let absorbed = try await merges.createEvent(memberArticleIDs: [fragment.id]).id
        let queued = try await merges.createEvent(memberArticleIDs: [waiting.id]).id
        try await merges.recordNotification(
            PlannedBanner(
                lane: .priority, grouped: false, thread: absorbed, sound: true,
                announces: [absorbed: EventFeedSummary.titleKey(fragment.title)]), at: now)
        let stale = QueuedPriority(event: queued, title: waiting.title, score: 0.8, leadKey: "old", story: waiting.id)
        try await merges.queuePriority([stale], at: now)
        _ = try await merges.mergeEvents(absorbed, into: survivor)
        _ = try await merges.mergeEvents(queued, into: survivor)
        let ledger = try await merges.notificationLedger(now: now)
        let leadKey = EventFeedSummary.titleKey(lead.title)
        expectEqual(
            ledger.announced, [survivor: .init(leadKey: leadKey, lane: .priority)],
            "The survivor inherits the absorbed announcement and its lane, under its own lead headline")
        expectEqual(
            ledger.priorityQueue,
            [QueuedPriority(event: survivor, title: waiting.title, score: 0.8, leadKey: leadKey, story: waiting.id)],
            "A waiting priority key moves to the survivor with its story")
        let quiet = NotificationService.plan(
            new: [(article: later, score: 0.9)], pending: [:],
            delivery: NotificationDelivery(
                mode: .full, events: [later.id: survivor], publishers: [survivor: 2],
                leadTitles: [survivor: lead.title], now: now, ledger: ledger))
        expectTrue(quiet.banners.isEmpty, "A breaking report of the merged event posts no second banner")
        await merges.close()
    }

    @MainActor
    static func testArticleStoreErrorResilience() async {
        print("  - Testing ArticleStore Error Resilience & Database Failures...")

        let db = DatabaseEngine(path: ":memory:")
        try? await db.open()
        let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()

        let article = FeedArticle(
            title: "Test Error Article", link: "https://example.com/error", guid: "test-err-guid", description: "Test",
            pubDate: Date(), source: "Test")
        await store.batchUpsert(articles: [article], feedUrl: "https://example.com/feed")

        // Force close the database to trigger failure scenarios
        await db.close()

        // 1. toggleSave returns false on failure (PR #18)
        let savedResult = await store.toggleSave(article: article)
        expectFalse(savedResult, "toggleSave should return false when database throws an error")

        // 2. markAsRead catches error and does not mutate in-memory read state (PR #19)
        await store.markAsRead(id: "test-err-guid", isRead: true)
        expectFalse(
            store.readArticleIDs.contains("test-err-guid"),
            "readArticleIDs should not contain ID when DB markRead fails")

        // 3. markAllAsRead catches error gracefully without crashing (PR #20)
        await store.markAllAsRead()
    }

    @MainActor
    static func testSystemErrorHardeningAndResilience() async {
        print("  - Testing System Error Hardening & Resilience across Coordinators and Views...")

        // 1. FeedManager.addFeed Boolean feedback
        let suite = testDefaultsSuite("test.error.feedmanager")
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaults(suite) }
        let settings = AppSettings(defaults: defaults)
        let db = DatabaseEngine(path: ":memory:")
        let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        let manager = FeedManager(
            settings: settings, store: store, schedulesRefresh: false,
            fetchBatch: { urls, _ in urls.map { ($0, [], nil, nil) } },
            notifyBatch: { _, _ in })

        let validURL = "https://example.com/feed.xml"
        let addedFirst = manager.addFeed(url: validURL)
        expectTrue(addedFirst, "Adding a new valid feed returns true")
        let addedDuplicate = manager.addFeed(url: validURL)
        expectFalse(addedDuplicate, "Adding a duplicate feed returns false")
        let addedInvalid = manager.addFeed(url: "https://")
        expectFalse(addedInvalid, "Adding an invalid scheme-only URL returns false")
        let addedEmpty = manager.addFeed(url: "   ")
        expectFalse(addedEmpty, "Adding an empty/whitespace URL returns false")
        manager.stopBackgroundWork()

        // 2. MigrationCoordinator corrupt legacy data handling
        let migrationSuite = testDefaultsSuite("test.error.migration")
        let migrationDefaults = UserDefaults(suiteName: migrationSuite)!
        defer { removeTestDefaults(migrationSuite) }
        migrationDefaults.set(Data("corrupted JSON content".utf8), forKey: "saved_articles")
        let migrationCoordinator = MigrationCoordinator(database: db, userDefaults: migrationDefaults)
        do {
            let stats = try await migrationCoordinator.migrateIfNeeded()
            expectEqual(stats.savedStories, 0, "Corrupted legacy saved stories are gracefully skipped")
        } catch {
            expectTrue(false, "migrateIfNeeded should not rethrow legacy JSON parsing failure: \(error)")
        }

        // 3. SentenceEmbedder corrupt file handling
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let corruptVocab = tempDir.appendingPathComponent("vocab.txt")
        try? "invalid vocab file".write(to: corruptVocab, atomically: true, encoding: .utf8)
        let corruptModel = tempDir.appendingPathComponent("minilm.mlmodelc")
        try? "invalid coreml model".write(to: corruptModel, atomically: true, encoding: .utf8)
        let embedder = SentenceEmbedder(modelURL: corruptModel, vocabURL: corruptVocab)
        let available = await embedder.isAvailable
        expectFalse(available, "SentenceEmbedder with corrupted files gracefully sets isAvailable to false")

        // 4. OverviewGenerationCoordinator graceful error handling when database closed
        let failingDb = DatabaseEngine(path: ":memory:")
        let failingStore = ArticleStore(database: failingDb, spotlightIndexer: MockSpotlightIndexer())
        let coordinator = OverviewGenerationCoordinator(
            store: failingStore, queue: EnrichmentQueue(store: failingStore))
        await failingDb.close()
        let result = await coordinator.requestOverview(
            eventID: "err-event", eventTitle: "Error Event", membershipVersion: 1,
            articles: [
                FeedArticle(
                    title: "Test", link: "https://example.com/item", guid: "g1",
                    description: "Desc", pubDate: Date(), source: "Src")
            ])
        expectTrue(result == nil, "requestOverview with failing database returns nil without crashing")
    }

    @MainActor
    static func testAppContainerWiring() async {
        print("  - Testing AppContainer wiring...")

        let suite = testDefaultsSuite("test.container")
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaults(suite) }
        let settings = AppSettings(defaults: defaults)
        let store = ArticleStore(database: DatabaseEngine(path: ":memory:"), spotlightIndexer: MockSpotlightIndexer())
        let feeds = FeedManager(settings: settings, store: store, schedulesRefresh: false)
        let reads = ReadManager(articleStore: store)
        let saved = SavedStoriesManager(articleStore: store)
        let container = AppContainer(
            appSettings: settings, articleStore: store, feedManager: feeds, readManager: reads, savedStories: saved)
        expectTrue(container.appSettings === settings, "Injected settings wired")
        expectTrue(container.articleStore === store, "Injected store wired")
        expectTrue(container.readManager === reads, "Injected read manager wired")
        expectTrue(container.savedStories === saved, "Injected saved manager wired")
    }

    @MainActor
    static func testReadManagerReconciliationCache() async throws {
        print("  - Testing ReadManager Reconciliation Cache...")
        // Saves and unsaves queue Spotlight updates; the test checks persistence, not the host's Spotlight service.
        let store = ArticleStore(database: DatabaseEngine(path: ":memory:"), spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        let rm = ReadManager(articleStore: store)
        let rawId = "http://example.com/test-article-perf?utm_source=news&utm_medium=rss"
        await store.batchUpsert(articles: [
            FeedArticle(
                title: "Read", link: rawId, guid: ArticleIdentity.reconcileLegacyId(rawId), description: "Text",
                pubDate: Date(), source: "Test")
        ])
        let isReadInitial = rm.isRead(rawId)
        // Repeat query to verify cached resolution works idempotently
        expectEqual(rm.isRead(rawId), isReadInitial, "Cached resolution matches initial read state")
        rm.markAsRead(rawId)
        expectTrue(rm.isRead(rawId), "Marked as read should reflect in cached lookup")
        for _ in 0..<100 {
            if store.isRead(ArticleIdentity.reconcileLegacyId(rawId)) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        expectTrue(store.isRead(ArticleIdentity.reconcileLegacyId(rawId)), "Read writes use the injected store")

        // Mark All as Read: one batch write, already-read stories untouched, the cache answers at once.
        let batch = ["batch-a", "batch-b", "batch-c"].map {
            FeedArticle(
                title: $0, link: "https://example.com/\($0)", guid: $0, description: "Text", pubDate: Date(),
                source: "Test")
        }
        await store.batchUpsert(articles: batch)
        rm.markAsRead(ids: batch.map(\.id) + [rawId])
        expectTrue(batch.allSatisfy { rm.isRead($0.id) }, "A batch marks every listed story read immediately")
        await rm.waitForPendingChanges()
        expectTrue(batch.allSatisfy { store.isRead($0.id) }, "The batch is persisted through the injected store")
        expectTrue(store.isRead(ArticleIdentity.reconcileLegacyId(rawId)), "Stories already read stay read")

        let article = FeedArticle(
            title: "Saved", link: "https://example.com/saved", guid: "isolated-save", description: "Text",
            pubDate: Date(), source: "Test")
        let saved = SavedStoriesManager(articleStore: store)
        saved.save(article)
        for _ in 0..<100 {
            if store.isSaved(article) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        expectTrue(store.isSaved(article), "Save writes use the injected store")
        saved.remove(article)
        saved.remove(article)
        for _ in 0..<100 {
            if !store.isSaved(article) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        expectFalse(store.isSaved(article), "Repeated removal cannot re-save an article")
        _ = await store.setSaved(article: article, isSaved: false)
        let persistedSaved = try await store.database.isSaved(articleId: article.id)
        expectFalse(persistedSaved, "Explicit unsave is idempotent in SQLite")
    }

    static func testMemoryLeakMitigationsAndErrorHandling() async throws {
        print("  - Testing Resource Leak Mitigations & Error Resilience...")

        // 1. DecodedImageCache bounds and clear
        await MainActor.run {
            DecodedImageCache.clear()
            expectEqual(DecodedImageCache.images.countLimit, 24, "The full-size cache bounds its image count")
            expectEqual(DecodedImageCache.cardImages.countLimit, 90, "The card cache bounds its image count")
            expectEqual(
                DecodedImageCache.images.totalCostLimit + DecodedImageCache.cardImages.totalCostLimit,
                192 * 1024 * 1024, "Card and full-size caches together keep the 192 MB ceiling")
        }

        // Test that clear() cancels pending tasks and prevents insertion
        let slowLoader: @Sendable (URL, Int) async throws -> CGImage = { _, _ in
            try await Task.sleep(for: .milliseconds(500))
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let ctx = CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            return ctx.makeImage()!
        }
        let testURL = URL(string: "https://example.com/slow_image_\(UUID().uuidString).jpg")!
        let loadTask = Task { @MainActor in
            _ = try? await DecodedImageCache.load(testURL, using: slowLoader)
        }
        try await Task.sleep(for: .milliseconds(30))
        await MainActor.run {
            DecodedImageCache.clear()
        }
        _ = await loadTask.value
        await MainActor.run {
            expectTrue(
                DecodedImageCache.images.object(forKey: testURL as NSURL) == nil,
                "DecodedImageCache must not contain image from cancelled load")
        }

        // Cancelling the only waiter stops the shared download; a clear() does not let a finished old load
        // remove a newer load's entry.
        final class LoaderProbe: @unchecked Sendable {
            private let lock = NSLock()
            private var startedCount = 0
            private var cancelledCount = 0
            var started: Int { lock.withLock { startedCount } }
            var cancelled: Int { lock.withLock { cancelledCount } }
            func recordStart() { lock.withLock { startedCount += 1 } }
            func recordCancel() { lock.withLock { cancelledCount += 1 } }
            var loader: @Sendable (URL, Int) async throws -> CGImage {
                { [self] _, _ in
                    recordStart()
                    do { try await Task.sleep(for: .seconds(30)) } catch {
                        recordCancel()
                        throw error
                    }
                    throw CancellationError()
                }
            }
        }
        let probe = LoaderProbe()
        let cancelURL = URL(string: "https://example.com/cancel_\(UUID().uuidString).jpg")!
        let first = Task { @MainActor in _ = try? await DecodedImageCache.load(cancelURL, using: probe.loader) }
        let second = Task { @MainActor in _ = try? await DecodedImageCache.load(cancelURL, using: probe.loader) }
        await eventually("Both waiters join the shared download") {
            await MainActor.run { DecodedImageCache.sharedLoad(for: cancelURL)?.waiters == 2 }
        }
        first.cancel()
        await eventually("The first cancellation is recorded") {
            await MainActor.run { DecodedImageCache.sharedLoad(for: cancelURL)?.cancelledWaiters == 1 }
        }
        expectEqual(probe.cancelled, 0, "A shared download keeps running while a waiter is left")
        second.cancel()
        _ = await first.value
        _ = await second.value
        expectEqual(probe.started, 1, "Two waiters on one URL share one download")
        expectEqual(probe.cancelled, 1, "The shared download stops once its last waiter cancels")
        await MainActor.run {
            expectTrue(
                DecodedImageCache.sharedLoad(for: cancelURL) == nil, "A cancelled shared download leaves the table")
        }

        // A finished old load must not delete the entry of the load that replaced it after a clear().
        let oldProbe = LoaderProbe()
        let newProbe = LoaderProbe()
        let thirdProbe = LoaderProbe()
        let replaceURL = URL(string: "https://example.com/replace_\(UUID().uuidString).jpg")!
        let oldCaller = Task { @MainActor in _ = try? await DecodedImageCache.load(replaceURL, using: oldProbe.loader) }
        await eventually("The old load registers") {
            await MainActor.run { DecodedImageCache.sharedLoad(for: replaceURL)?.waiters == 1 }
        }
        await MainActor.run { DecodedImageCache.clear() }
        let newCaller = Task { @MainActor in _ = try? await DecodedImageCache.load(replaceURL, using: newProbe.loader) }
        await eventually("The replacement registers") {
            await MainActor.run { DecodedImageCache.sharedLoad(for: replaceURL)?.waiters == 1 }
        }
        _ = await oldCaller.value  // the old load finishes, cancelled by clear()
        let replacement = await MainActor.run { DecodedImageCache.sharedLoad(for: replaceURL) }
        expectTrue(replacement != nil, "A finished old load leaves the replacement registered")
        let thirdCaller = Task { @MainActor in
            _ = try? await DecodedImageCache.load(replaceURL, using: thirdProbe.loader)
        }
        await eventually("A third caller joins the replacement") {
            await MainActor.run { DecodedImageCache.sharedLoad(for: replaceURL)?.waiters == 2 }
        }
        await MainActor.run {
            expectTrue(
                DecodedImageCache.sharedLoad(for: replaceURL) === replacement, "The third caller shares the replacement"
            )
        }
        expectEqual(thirdProbe.started, 0, "The third caller starts no download of its own")
        newCaller.cancel()
        thirdCaller.cancel()
        _ = await newCaller.value
        _ = await thirdCaller.value
        expectEqual(newProbe.started, 1, "The replacement downloads once")

        await MainActor.run {
            let oldLoad = DecodedImageCache.SharedLoad(task: Task { throw CancellationError() })
            oldLoad.join()
            oldLoad.join()
            expectFalse(oldLoad.leave(), "One of two waiters cancelling keeps the download")
            expectTrue(oldLoad.leave(), "The last waiter cancelling stops the download")
        }

        // 2. DatabaseEngine directory creation on custom path & deinit safety
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "news_test_dir_\(UUID().uuidString)")
        let nestedDBPath = tempDir.appendingPathComponent("nested/deep/test.sqlite3").path
        do {
            let engine = DatabaseEngine(path: nestedDBPath)
            try await engine.open()
            expectTrue(
                FileManager.default.fileExists(atPath: nestedDBPath),
                "open() must create parent directories if missing")
            await engine.close()
        }
        try? FileManager.default.removeItem(at: tempDir)

        // A fetch of nothing, long after startup, returns nothing and does not trip over the cooldown pruning.
        let clock = TestClock(Date())
        let fetcher = FeedFetcher(now: { clock.now })
        clock.advance(by: 86400)
        expectEqual(await fetcher.fetchAllFeeds(urls: []).count, 0, "Fetching no feeds returns no results")
    }

    // MARK: - Epic N (#559, #560, #561) System Integration Unit Tests

    @MainActor
    static func testNotificationActionsAndRouting() async {
        print("  - Testing Notification actions and routing (#560)...")
        let category = NotificationActionIdentifier.makeCategory()
        expectEqual(category.identifier, "ARTICLE_ACTIONS", "Category identifier is ARTICLE_ACTIONS (#560)")
        expectEqual(category.actions.map(\.identifier), ["SAVE_ACTION", "MARK_READ_ACTION", "OPEN_ACTION"])
        expectEqual(category.actions.map(\.title), ["Save", "Mark as Read", "Open"])
        expectTrue(category.actions[2].options.contains(.foreground), "Open action brings app to foreground")

        let db = DatabaseEngine(path: ":memory:")
        let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        let readManager = ReadManager(articleStore: store)
        let savedManager = SavedStoriesManager(articleStore: store)

        let article = FeedArticle(
            storedID: "notif-story-1",
            title: "Mars Sample Return Update",
            link: "https://example.com/mars-1",
            guid: "notif-story-1",
            description: "Orbiter rendezvous confirmed.",
            pubDate: Date(),
            source: "Space Wire"
        )
        await store.batchUpsert(articles: [article], feedUrl: "https://example.com/rss")

        // 1. SAVE_ACTION saves the story
        await NotificationActionRouter.route(
            actionIdentifier: NotificationActionIdentifier.save,
            userInfo: ["articleID": article.id, "articleLink": article.link],
            articleStore: store,
            readManager: readManager,
            savedStories: savedManager,
            activateApp: {}
        )
        await savedManager.waitForPendingChanges()
        expectTrue(savedManager.isSaved(article), "SAVE_ACTION routes to SavedStoriesManager (#560)")

        // 2. MARK_READ_ACTION marks the story as read
        await NotificationActionRouter.route(
            actionIdentifier: NotificationActionIdentifier.markRead,
            userInfo: ["articleID": article.id, "articleLink": article.link],
            articleStore: store,
            readManager: readManager,
            savedStories: savedManager,
            activateApp: {}
        )
        await readManager.waitForPendingChanges()
        expectTrue(readManager.isRead(article.id), "MARK_READ_ACTION routes to ReadManager (#560)")

        // 3. OPEN_ACTION activates app and sets pendingNavigation
        var activatedBeforeNavigation = false
        var activated = false
        await NotificationActionRouter.route(
            actionIdentifier: NotificationActionIdentifier.open,
            userInfo: ["articleID": article.id, "articleLink": article.link],
            articleStore: store,
            readManager: readManager,
            savedStories: savedManager,
            activateApp: {
                activated = true
                if store.pendingNavigation == nil {
                    activatedBeforeNavigation = true
                }
            }
        )
        expectTrue(activated, "OPEN_ACTION activates the application (#560)")
        expectTrue(activatedBeforeNavigation, "OPEN_ACTION activates app before pendingNavigation is set")
        expectEqual(store.pendingNavigation?.articleID, article.id, "OPEN_ACTION sets pendingNavigation articleID")
        expectEqual(store.pendingNavigation?.link, article.link, "OPEN_ACTION sets pendingNavigation link")

        // 4. Fallback by articleLink when articleID is missing
        store.pendingNavigation = nil
        await NotificationActionRouter.route(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: ["articleLink": article.link],
            articleStore: store,
            readManager: readManager,
            savedStories: savedManager,
            activateApp: {}
        )
        expectEqual(store.pendingNavigation?.link, article.link, "Default action falls back to articleLink")

        // 5. Missing userInfo is ignored safely
        store.pendingNavigation = nil
        await NotificationActionRouter.route(
            actionIdentifier: NotificationActionIdentifier.open,
            userInfo: [:],
            articleStore: store,
            readManager: readManager,
            savedStories: savedManager,
            activateApp: {}
        )
        expectTrue(store.pendingNavigation == nil, "Empty userInfo is ignored safely")

        // 6. Save action on a pruned story does not insert placeholder (#890)
        let prunedID = "pruned-story-id"
        let savedCountBefore = savedManager.savedArticles.count
        await NotificationActionRouter.route(
            actionIdentifier: NotificationActionIdentifier.save,
            userInfo: ["articleID": prunedID, "articleLink": "https://example.com/pruned"],
            articleStore: store,
            readManager: readManager,
            savedStories: savedManager,
            activateApp: {}
        )
        await savedManager.waitForPendingChanges()
        expectEqual(
            savedManager.savedArticles.count, savedCountBefore,
            "Pruned story is not saved as a placeholder (#890)")
        expectEqual(
            store.operationError, "This story is no longer available in your archive.",
            "Missing story reports clear error message (#890)")

        // 7. Save action on storage failure reports load failure rather than pruned story
        let errorDB = DatabaseEngine(path: ":memory:")
        let errorStore = ArticleStore(database: errorDB, spotlightIndexer: MockSpotlightIndexer())
        await errorStore.initialize()
        await errorStore.waitForStartup()
        await errorDB.close()
        await NotificationActionRouter.route(
            actionIdentifier: NotificationActionIdentifier.save,
            userInfo: ["articleID": "error-id", "articleLink": "https://example.com/error"],
            articleStore: errorStore,
            readManager: readManager,
            savedStories: savedManager,
            activateApp: {}
        )
        expectEqual(
            errorStore.operationError, "The notification story could not be loaded. Please try again.",
            "Storage lookup failure is distinguished from a pruned story")

        // 8. Mark as read on a deleted or pruned story returns quietly without error (#1144)
        store.operationError = nil
        let deletedID = "deleted-story-id"
        await NotificationActionRouter.route(
            actionIdentifier: NotificationActionIdentifier.markRead,
            userInfo: ["articleID": deletedID, "articleLink": "https://example.com/deleted"],
            articleStore: store,
            readManager: readManager,
            savedStories: savedManager,
            activateApp: {}
        )
        await readManager.waitForPendingChanges()
        expectFalse(readManager.isRead(deletedID), "Pruned story is not marked as read")
        expectTrue(store.operationError == nil, "Mark as read on a deleted story raises no operationError (#1144)")
        await db.close()
    }

    /// #1144: Mark as Read on a banner for a deleted story returns quietly without operationError.
    @MainActor
    static func testMarkReadPrunedStoryBannerRaisesNoOperationError() async {
        print("  - Testing Mark as Read on a banner for a deleted story raises no error (#1144)...")
        let db = DatabaseEngine(path: ":memory:")
        let store = ArticleStore(database: db, spotlightIndexer: MockSpotlightIndexer())
        await store.initialize()
        let readManager = ReadManager(articleStore: store)
        let savedManager = SavedStoriesManager(articleStore: store)

        store.operationError = nil
        await NotificationActionRouter.route(
            actionIdentifier: NotificationActionIdentifier.markRead,
            userInfo: ["articleID": "nonexistent-id", "articleLink": "https://example.com/nonexistent"],
            articleStore: store,
            readManager: readManager,
            savedStories: savedManager,
            activateApp: {}
        )
        await readManager.waitForPendingChanges()
        expectFalse(readManager.isRead("nonexistent-id"), "Nonexistent story is not marked as read")
        expectTrue(store.operationError == nil, "Mark as read for an ID with no row raises no operationError (#1144)")
        await db.close()
    }

}
