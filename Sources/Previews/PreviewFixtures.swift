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

#if DEBUG
    import SwiftUI

    /// Deterministic sample data for Xcode previews (#577). Every date derives from one fixed moment, no image URL is set
    /// and the library is an in-memory SQLite database, so a preview never reaches the network, a library file or a model.
    enum PreviewFixtures {
        /// 2026-10-30 07:00 UTC, the morning edition the Briefing captures use.
        static let now = Date(timeIntervalSince1970: 1_793_372_400)

        static func article(
            _ id: String, title: String, source: String = "Reuters", category: String? = "World",
            minutesAgo: Double = 30, description: String = "", document: ReaderDocument? = nil
        ) -> FeedArticle {
            FeedArticle(
                storedID: id, title: title, link: "https://preview.example/\(id)", guid: id, description: description,
                pubDate: now.addingTimeInterval(-minutesAgo * 60), source: source,
                fullContent: document.map { $0.blocks.map(\.text).joined(separator: "\n\n") }, category: category,
                readerDocument: document)
        }

        static let longTitle =
            "Negotiators from fourteen countries agree on a provisional framework for shared river management after "
            + "three weeks of overnight sessions, leaving the hardest questions on water rights for a later round"

        static let articles: [FeedArticle] = [
            article(
                "harbour", title: "Harbour authority reopens the northern channel after storm damage",
                description: "Ferries resume a reduced timetable while divers inspect the breakwater."),
            article(
                "chips", title: "Chipmakers report steady orders as memory prices level off", source: "Financial Desk",
                category: "Business", minutesAgo: 95,
                description: "Quarterly results point to a slower but stable second half."),
            article(
                "probe", title: "Solar probe completes its closest pass yet", source: "Science Weekly",
                category: "Science", minutesAgo: 240,
                description: "Instruments returned data through the whole approach."),
        ]

        static let longArticle = article(
            "long", title: longTitle, source: "International Correspondents Network",
            description: String(repeating: "Delegates described the talks as difficult but constructive. ", count: 6))

        static let readerArticle = article(
            "reader", title: "City council approves a ten-year plan for cycle lanes", source: "Metro Desk",
            category: "Politics", description: "The plan links every district to the centre by 2036.",
            document: ReaderDocument(blocks: [
                ReaderBlock(kind: .standfirst, text: "The plan links every district to the centre by 2036."),
                ReaderBlock(kind: .paragraph, text: paragraph("The council voted 31 to 12 on Thursday evening")),
                ReaderBlock(kind: .heading, text: "Funding"),
                ReaderBlock(
                    kind: .paragraph, text: paragraph("Most of the money comes from the regional transport fund")),
                ReaderBlock(kind: .quote, text: "We are building for the next generation, not the next election."),
                ReaderBlock(kind: .paragraph, text: paragraph("Work on the first two corridors starts in the spring")),
            ]))

        static let longReaderArticle = article(
            "reader-long", title: longTitle, source: "International Correspondents Network",
            document: ReaderDocument(
                blocks: (1...12).map { ReaderBlock(kind: .paragraph, text: paragraph("Section \($0) of the account")) })
        )

        private static func paragraph(_ opening: String) -> String {
            opening
                + ", after a debate that ran for most of the afternoon and drew comments from residents, businesses "
                + "and neighbouring councils. Officials said the timetable depends on contractors and on the weather, and "
                + "that a progress report will be published every six months so the public can follow each stage."
        }

        static func eventSummary(for representative: FeedArticle, publishers: [String]) -> EventFeedSummary {
            EventFeedSummary(
                eventID: "event-\(representative.id)", membershipVersion: 1, seenVersion: nil,
                members: publishers.enumerated().map { index, source in
                    EventFeedMember(
                        articleID: index == 0 ? representative.id : "\(representative.id)-\(index)", source: source,
                        title: representative.title, date: now.addingTimeInterval(Double(-index) * 600),
                        joinedVersion: 1,
                        isRead: false, isSaved: false)
                })
        }

        static let event = eventSummary(
            for: articles[0], publishers: ["Reuters", "Associated Press", "BBC News", "The Guardian"])

        static let longEvent = eventSummary(
            for: longArticle,
            publishers: [
                "International Correspondents Network", "Associated Press", "Agence France-Presse", "Deutsche Welle",
                "Al Jazeera English", "NHK World", "ABC News Australia",
            ])

        static let entries: [FeedEntry] =
            [.event(event, representative: articles[0], visibleMembers: [articles[0]])]
            + articles.dropFirst().map {
                .article($0)
            }

        // MARK: Feed and publisher health

        static let feedURL = "https://preview.example/feed.xml"

        /// One health line per refresh state: never checked, responding, failing with a retry, and inactive.
        static let health: [String: FeedHealth] = [
            "Not checked": FeedHealth(nil, now: now),
            "Responding": FeedHealth(
                FeedFetchState(
                    lastFetchedAt: now, latestItemAt: now.addingTimeInterval(-3600), itemCount: 20, fullTextItems: 18),
                now: now),
            "Failing": FeedHealth(
                FeedFetchState(
                    failures: 3, retryAt: now.addingTimeInterval(1800), lastFailureKind: .timeout,
                    lastFetchedAt: now.addingTimeInterval(-86_400), latestItemAt: now.addingTimeInterval(-90_000),
                    itemCount: 20, fullTextItems: 2),
                now: now),
            "Inactive": FeedHealth(
                FeedFetchState(
                    lastFetchedAt: now, latestItemAt: now.addingTimeInterval(-45 * 86_400), itemCount: 4,
                    fullTextItems: 0),
                now: now),
        ]

        static func publisherRow(
            _ name: String, attempts: Double, successes: Double, items: Int, fullReader: Int, teaser: Int = 0,
            blocked: Int = 0, health: FeedHealth? = nil
        ) -> PublisherHealthRow {
            var observed = FeedHealthObservations()
            observed.attempts = attempts
            observed.successes = successes
            observed.latencyTotal = successes * 0.4
            observed.recentItems = items
            observed.oldestRecentItem = now.addingTimeInterval(-7 * 86_400)
            observed.fullReader = fullReader
            observed.teaser = teaser
            observed.blocked = blocked
            return PublisherHealthRow(
                feedURL: "https://\(name.lowercased().filter(\.isLetter)).example/feed.xml", storedPublisher: name,
                metrics: FeedHealthMetrics(observed, now: now), health: health)
        }

        static let publisherRows: [PublisherHealthRow] = [
            publisherRow("Reuters", attempts: 40, successes: 40, items: 140, fullReader: 9),
            publisherRow("Metro Desk", attempts: 40, successes: 31, items: 35, fullReader: 2, teaser: 5),
            publisherRow(
                "Science Weekly", attempts: 40, successes: 4, items: 3, fullReader: 0, blocked: 4,
                health: health["Failing"]),
            publisherRow(
                "International Correspondents Network of Independent Regional Newspapers", attempts: 12, successes: 12,
                items: 2, fullReader: 3, health: health["Inactive"]),
        ]

        // MARK: Briefing

        static let briefing = FiniteBriefing(startedAt: now, articles: entries.map(\.representative))

        /// Every board module filled from the modules' own capture fixtures, as the Briefing captures show it.
        static var boardData: BriefingBoardData { .captureFixture(details: BriefingStoryDetails()) }

        /// Previews have nowhere to navigate, so every action does nothing.
        static var briefingActions: BriefingActions {
            BriefingActions(
                onOpenArticle: { _ in
                    // No navigation in a preview.
                },
                onOpenEvent: { _ in
                    // No navigation in a preview.
                },
                onStartNewBriefing: {
                    // No new edition in a preview.
                },
                onBackToToday: {
                    // No navigation in a preview.
                })
        }

        /// Never wakes, so the hero carousel holds its first story.
        struct StillClock: CarouselClock {
            func sleep(seconds: Double) async throws {
                try await Task.sleep(for: .seconds(86_400 * 365))
            }
        }

        // MARK: Entity dossier (W2 #716)

        static let entity = EntityRecord(
            id: "organization:harbour-authority", canonicalName: "Harbour Authority", entityType: .organization,
            storyCount: 21, firstSeen: now.addingTimeInterval(-26 * 86_400), lastSeen: now, centrality: 0.004)

        static let relatedEntities: [RelatedEntity] = [
            RelatedEntity(
                entity: EntityRecord(
                    id: "place:northern-channel", canonicalName: "Northern Channel", entityType: .place, storyCount: 9,
                    firstSeen: now.addingTimeInterval(-20 * 86_400), lastSeen: now, centrality: 0.002),
                sharedStories: 8, score: 0.31),
            RelatedEntity(
                entity: EntityRecord(
                    id: "person:maria-ortega", canonicalName: "Maria Ortega", entityType: .person, storyCount: 6,
                    firstSeen: now.addingTimeInterval(-12 * 86_400), lastSeen: now, centrality: 0.001),
                sharedStories: 4, score: 0.22),
        ]

        /// Thirty days of coverage with a quiet start and a busy last week.
        static let entityDossier = EntityDossier(
            entity: entity,
            coverage: [0, 0, 1, 0, 0, 2, 1, 0, 0, 0, 1, 0, 3, 1, 0, 0, 2, 0, 1, 0, 0, 4, 2, 1, 0, 1, 3, 2, 1, 2]
                .enumerated().map { day, count in
                    EntityCoverageDay(
                        day: DatabaseEngine.windowStart(now: now).addingTimeInterval(Double(day) * 86_400),
                        storyCount: count)
                },
            publishers: [
                EntityPublisherShare(publisher: "Reuters", storyCount: 9, share: 0.43),
                EntityPublisherShare(publisher: "Associated Press", storyCount: 7, share: 0.33),
                EntityPublisherShare(publisher: "Metro Desk", storyCount: 5, share: 0.24),
            ],
            recentStories: articles.map {
                EntityStoryReference(id: $0.id, title: $0.title, publisher: $0.source, date: $0.pubDate)
            },
            related: relatedEntities)

        /// Chips and dossiers without a library.
        static let entitySource = EntitySource(
            entities: { _ in [entity] + relatedEntities.map(\.entity) }, dossier: { _ in entityDossier })

        // MARK: Hotspot map (W4 #718)

        /// Five places from the bundled lookup: two cities, a territory, a country and a sea, which draw differently.
        static let hotspotPins: [HotspotClusterPin] = {
            let service = HotspotProjectionService()
            func pin(_ name: String, tension: Double, stories: Int) -> HotspotClusterPin? {
                guard let place = service.resolveLocation(for: name) else { return nil }
                return HotspotClusterPin(
                    id: place.name, title: place.name.capitalized, coordinate: place.coordinate, tensionScore: tension,
                    topPublisherIds: ["Reuters"], storyCount: stories, isApproximate: service.isApproximate(place.name))
            }
            return [
                pin("Kyiv", tension: 82, stories: 6), pin("Gaza", tension: 74, stories: 5),
                pin("Sudan", tension: 55, stories: 3), pin("Taipei", tension: 38, stories: 2),
                pin("Red Sea", tension: 31, stories: 2),
            ].compactMap { $0 }
        }()

        static let hotspotRegions: [HotspotRegion] = [("UA", 82.0, 1, 6), ("ME", 74.0, 1, 5), ("TW", 38.0, 1, 2)]
            .compactMap {
                id, tension, places, stories in
                HotspotProjectionService.regionAnchors.first { $0.id == id }.map {
                    HotspotRegion(
                        id: $0.id, name: $0.name, centroid: $0.centroid, tensionScore: tension,
                        activeClusterCount: places,
                        articleCount: stories)
                }
            }

        // MARK: Compare Perspectives (W3 #717)

        static let comparisonLeft = [
            "Harbour authority reopens the northern channel after storm damage",
            "Ferries resume a reduced timetable while divers inspect the breakwater.",
            "The authority said the channel will stay closed to freight until Friday.",
            "Residents on the quay were told to expect noise from repair crews overnight.",
        ]

        static let comparisonRight = [
            "Northern channel reopens to ferries after storm repairs",
            "A reduced ferry timetable starts today as divers check the breakwater for cracks.",
            "A port spokesperson blamed the delay on a late delivery of replacement bollards.",
        ]

        /// Hand-built alignment: two passages both reports have, one they word differently and one only the left has.
        /// Previews never run the embedder, so nothing here is computed.
        static let comparisonSession = DualReaderSession(
            clusterId: "preview", leftArticleId: "left", rightArticleId: "right", leftPublisherName: "Reuters",
            rightPublisherName: "Metro Desk",
            passageAlignments: [
                PassageContrastPair(
                    id: "0-0", leftPassageIndex: 0, rightPassageIndex: 0, leftSnippet: comparisonLeft[0],
                    rightSnippet: comparisonRight[0], similarityScore: 0.86, contrastType: .consensus),
                PassageContrastPair(
                    id: "1-1", leftPassageIndex: 1, rightPassageIndex: 1, leftSnippet: comparisonLeft[1],
                    rightSnippet: comparisonRight[1], similarityScore: 0.83, contrastType: .consensus),
                PassageContrastPair(
                    id: "2-2", leftPassageIndex: 2, rightPassageIndex: 2, leftSnippet: comparisonLeft[2],
                    rightSnippet: comparisonRight[2], similarityScore: 0.61, contrastType: .divergence),
                PassageContrastPair(
                    id: "3-2", leftPassageIndex: 3, rightPassageIndex: 2, leftSnippet: comparisonLeft[3],
                    rightSnippet: comparisonRight[2], similarityScore: 0.2, contrastType: .uniqueLead,
                    uniqueSide: .left),
            ])
    }

    /// The stores a previewed view reads from the environment, built once per preview session: an in-memory library,
    /// settings in a preview-only defaults domain (AI analysis off, so the reader never loads a model) and a feed manager
    /// that never schedules or fetches.
    @MainActor
    final class PreviewContext {
        /// One per preview process, so every preview reuses the same stores; views that take a store as a parameter
        /// (`EventCardView`) read it here.
        static let shared = PreviewContext()

        let defaults: UserDefaults
        let settings: AppSettings
        let store: ArticleStore
        let feedManager: FeedManager
        let readManager: ReadManager
        let savedStories: SavedStoriesManager
        let themeManager: ThemeManager
        let tension = WorldTensionModel()

        private init() {
            let domain = "com.marspater.news.previews"
            let defaults = UserDefaults(suiteName: domain) ?? .standard
            defaults.removePersistentDomain(forName: domain)
            defaults.set(false, forKey: AppSettings.aiEnabledKey)
            self.defaults = defaults
            settings = AppSettings(defaults: defaults)
            store = ArticleStore(database: DatabaseEngine(path: ":memory:"), spotlightIndexer: MockSpotlightIndexer())
            feedManager = FeedManager(
                settings: settings, store: store, schedulesRefresh: false,
                fetchBatch: { _, _ in [] },
                notifyBatch: { _, _ in
                    // Previews post no notifications.
                },
                allowsBackgroundWork: { false })
            readManager = ReadManager(articleStore: store)
            savedStories = SavedStoriesManager(articleStore: store)
            themeManager = ThemeManager(defaults: defaults)
        }
    }

    /// Supplies the shared ``PreviewContext`` to a preview: `#Preview(traits: .modifier(PreviewEnvironment()))`.
    struct PreviewEnvironment: PreviewModifier {
        @MainActor static func makeSharedContext() async throws -> PreviewContext { PreviewContext.shared }

        func body(content: Content, context: PreviewContext) -> some View {
            content
                .environmentObject(context.settings)
                .environmentObject(context.store)
                .environmentObject(context.feedManager)
                .environmentObject(context.readManager)
                .environmentObject(context.savedStories)
                .environmentObject(context.themeManager)
                .environment(context.tension)
                .environment(\.readerImageLoader) { _, _ in throw URLError(.notConnectedToInternet) }
                .defaultAppStorage(context.defaults)
        }
    }

    extension View {
        /// The accessibility variant: the app's own Increase Contrast and Reduce Motion overrides and the largest text.
        func previewAccessibility() -> some View {
            environment(\.overrideContrast, .increased)
                .environment(\.overrideReduceMotion, true)
                .dynamicTypeSize(.accessibility3)
        }
    }
#endif
