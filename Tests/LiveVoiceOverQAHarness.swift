// Tests/LiveVoiceOverQAHarness.swift
// Live VoiceOver QA Harness on isolated data (Issue #155)
//
// Exercises live AppKit/SwiftUI view rendering, inspects the macOS Accessibility tree
// via AXUIElement, observes NSAccessibility announcements via AXObserver, records
// tree order and heading levels, and invokes exposed accessibility actions.
// Tree order is not VoiceOver cursor order; speech and rotor traversal still require a manual pass.

import Foundation
import SwiftUI
import AppKit
import ApplicationServices
import Accessibility
import Darwin

// MARK: - Accessibility Node Model

struct AXElementRecord {
    let element: AXUIElement?
    let role: String
    let subrole: String?
    let title: String?
    let description: String?
    let value: String?
    let hint: String?
    let headingLevel: Int?
    let actions: [String]
    let customActions: [String]
    let children: [AXElementRecord]

    var spokenText: String {
        if let desc = description, !desc.isEmpty { return desc }
        if let t = title, !t.isEmpty { return t }
        if let v = value, !v.isEmpty { return v }
        return ""
    }
}

// MARK: - Announcement Storage

final class AnnouncementBox: @unchecked Sendable {
    static let shared = AnnouncementBox()
    private var announcements: [(text: String, priority: Int)] = []
    private let lock = NSLock()

    func append(text: String, priority: Int) {
        lock.lock()
        defer { lock.unlock() }
        announcements.append((text, priority))
    }

    func getAnnouncements() -> [(text: String, priority: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return announcements
    }
}

private func axObserverCallback(
    observer: AXObserver,
    element: AXUIElement,
    notificationName: CFString,
    info: CFDictionary?,
    refcon: UnsafeMutableRawPointer?
) {
    if let dict = info as? [String: Any] {
        let text = (dict["NSAccessibilityAnnouncementKey"] as? String)
            ?? (dict[kAXAnnouncementKey as String] as? String)
            ?? ""
        let priority = (dict[kAXPriorityKey as String] as? Int)
            ?? (dict["NSAccessibilityPriorityKey"] as? Int)
            ?? 0
        if !text.isEmpty {
            AnnouncementBox.shared.append(text: text, priority: priority)
        }
    }
}

// MARK: - Accessibility Tree Traversal

func inspectAXElement(_ element: AXUIElement, maxDepth: Int = 15) throws -> AXElementRecord {
    var remainingNodes = 1000
    return try inspectAXNode(element, maxDepth: maxDepth,
        deadline: ProcessInfo.processInfo.systemUptime + 3, remainingNodes: &remainingNodes)
}

private func inspectAXNode(_ element: AXUIElement, maxDepth: Int, deadline: TimeInterval, remainingNodes: inout Int) throws -> AXElementRecord {
    guard remainingNodes > 0, ProcessInfo.processInfo.systemUptime < deadline else {
        throw QAFailure("Accessibility tree exceeded its three-second / 1,000-node inspection budget")
    }
    remainingNodes -= 1
    var names: CFArray?
    guard AXUIElementCopyAttributeNames(element, &names) == .success else {
        throw QAFailure("Could not read accessibility attributes (host may have exited)")
    }
    let supported = Set((names as? [String]) ?? [])
    func attribute(_ name: String) -> AnyObject? {
        guard supported.contains(name) else { return nil }
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return error == .success ? value : nil
    }
    let role = attribute(kAXRoleAttribute as String) as? String ?? "Unknown"
    let subrole = attribute(kAXSubroleAttribute as String) as? String
    let title = attribute(kAXTitleAttribute as String) as? String
    // Read rank only when the platform exports it; selectable headings may expose just AXHeading.
    let attributed = attribute("AXAttributedDescription") as? NSAttributedString
    let description = attribute(kAXDescriptionAttribute as String) as? String ?? attributed?.string
    let rawValue = attribute(kAXValueAttribute as String)
    let value = rawValue as? String ?? (rawValue as? NSNumber)?.stringValue
    let hint = attribute(kAXHelpAttribute as String) as? String
    var headingLevel = (attribute("AXHeadingLevel") as? NSNumber)?.intValue
    if headingLevel == nil, let attributed, attributed.length > 0 {
        headingLevel = (attributed.attribute(NSAttributedString.Key(AttributeScopes.AccessibilityAttributes.HeadingLevelAttribute.name),
            at: 0, effectiveRange: nil) as? NSNumber)?.intValue
    }

    var actionsVal: CFArray?
    AXUIElementCopyActionNames(element, &actionsVal)
    let rawActions = (actionsVal as? [String]) ?? []

    var customActions: [String] = []
    var standardActions: [String] = []
    for act in rawActions {
        if act.hasPrefix("Name:") {
            let lines = act.components(separatedBy: "\n")
            if let nameLine = lines.first(where: { $0.hasPrefix("Name:") }) {
                customActions.append(String(nameLine.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        } else {
            standardActions.append(act)
        }
    }

    var childrenRecords: [AXElementRecord] = []
    if maxDepth > 0 {
        var childrenVal: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenVal)
        if let children = childrenVal as? [AXUIElement] {
            for child in children {
                childrenRecords.append(try inspectAXNode(child, maxDepth: maxDepth - 1, deadline: deadline, remainingNodes: &remainingNodes))
            }
        }
    }

    return AXElementRecord(
        element: element,
        role: role,
        subrole: subrole,
        title: title,
        description: description,
        value: value,
        hint: hint,
        headingLevel: headingLevel,
        actions: standardActions,
        customActions: customActions,
        children: childrenRecords
    )
}

func flattenNavigationOrder(_ record: AXElementRecord) -> [AXElementRecord] {
    var list: [AXElementRecord] = []
    let containerRoles: Set<String> = [
        "AXWindow", "AXGroup", "AXScrollArea", "AXSplitGroup",
        "AXApplication", "AXMenuBar", "AXMenuBarItem", "AXMenu", "AXMenuItem"
    ]

    let isInteractiveOrHeading = record.role == "AXHeading"
        || record.role == "AXButton"
        || record.role == "AXLink"
        || record.role == "AXTextField"
        || !record.customActions.isEmpty

    let hasSpokenContent = !record.spokenText.isEmpty

    if (isInteractiveOrHeading || hasSpokenContent) && (!containerRoles.contains(record.role) || !record.customActions.isEmpty) {
        list.append(record)
    }

    for child in record.children {
        list.append(contentsOf: flattenNavigationOrder(child))
    }
    return list
}

// MARK: - Host State and Views

@MainActor
final class HostAppState: ObservableObject {
    @Published var activeMode: String = "LIST" // "LIST", "READER", "OVERVIEW"
    @Published var readerPath: NavigationPath = NavigationPath()

    var container: AppContainer?
    var store: ArticleStore?
    var settings: AppSettings?
    var manager: FeedManager?

    var fusionArticle: FeedArticle?
    var summitArticleAP: FeedArticle?
    var summitArticleReuters: FeedArticle?
    var summitArticleBBC: FeedArticle?
    var summitOverview: EventOverviewDocument?
}

@MainActor
struct HostRootView: View {
    @ObservedObject var state: HostAppState

    var body: some View {
        Group {
            if let container = state.container, let settings = state.settings,
               let store = state.store, let manager = state.manager {
                Group {
                    if state.activeMode == "LIST" {
                        MainView()
                    } else {
                        NavigationStack {
                            if state.activeMode == "READER", let article = state.fusionArticle {
                                ArticleDetailView(article: article, allArticles: [article], path: $state.readerPath,
                                    initialExperienceMode: .sourcePublication)
                            } else if let article = state.summitArticleAP, let overview = state.summitOverview {
                                ArticleDetailView(article: article,
                                    allArticles: [article, state.summitArticleReuters, state.summitArticleBBC].compactMap { $0 },
                                    path: $state.readerPath, overview: overview, initialExperienceMode: .eventOverview)
                            }
                        }
                    }
                }
                .environmentObject(container)
                .environmentObject(settings)
                .environmentObject(store)
                .environmentObject(manager)
                .environmentObject(container.themeManager)
                .environmentObject(container.readManager)
                .environmentObject(container.savedStories)
            } else {
                ProgressView("Loading fixtures…")
            }
        }
        .frame(minWidth: 900, minHeight: 650)
    }
}

// MARK: - Test Host Application

@MainActor
final class LiveVoiceOverHost {
    let state = HostAppState()
    var window: NSWindow?
    let tempDir: URL
    let db: DatabaseEngine
    let image: CGImage
    let suite: String
    var defaults: UserDefaults?
    var commandTask: Task<Void, Never>?
    var loadedImages: Set<URL> = []
    var imageObserver: NSObjectProtocol?

    init() throws {
        self.image = try fixtureImage()
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--fixture-directory"), arguments.indices.contains(index + 1) {
            self.tempDir = URL(fileURLWithPath: arguments[index + 1])
        } else {
            self.tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("news-vo-qa-\(UUID().uuidString)")
        }
        if let index = arguments.firstIndex(of: "--defaults-suite"), arguments.indices.contains(index + 1) {
            self.suite = arguments[index + 1]
        } else {
            self.suite = "test.vo.host.\(UUID().uuidString)"
        }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        self.db = DatabaseEngine(path: tempDir.appendingPathComponent("library.sqlite3").path)
    }

    func run() async throws {
        try await db.open()

        let defaults = UserDefaults(suiteName: suite)!
        self.defaults = defaults
        defaults.set(true, forKey: "groupsEventCoverage")
        defaults.set(false, forKey: "articleGridLayout")
        let settings = AppSettings(defaults: defaults)
        settings.aiEnabled = false
        settings.notificationsEnabled = false
        settings.feedURLs = []

        let store = ArticleStore(database: db)
        await store.initialize()

        let now = Date()

        // 1. Multi-source event: Global Climate Summit
        let artAP = FeedArticle(
            storedID: "art_ap_summit",
            title: "Global Climate Summit Reaches Binding Agreement",
            link: "https://apnews.invalid/climate-summit",
            guid: "ap-summit-01",
            description: "Delegates adopted binding emission milestones in Geneva.",
            pubDate: now.addingTimeInterval(-1800),
            source: "Associated Press",
            fullContent: "Delegates from 195 nations signed the treaty.",
            readerDocument: ReaderDocument(blocks: [
                ReaderBlock(kind: .paragraph, text: "Delegates from 195 nations signed the treaty.")
            ])
        )

        let artReuters = FeedArticle(
            storedID: "art_reuters_summit",
            title: "Geneva Conference Concludes with $100B Resilience Fund",
            link: "https://reuters.invalid/geneva-fund",
            guid: "reuters-summit-01",
            description: "Financial commitments secured for vulnerable nations.",
            pubDate: now.addingTimeInterval(-3600),
            source: "Reuters",
            fullContent: "A $100 billion annual climate resilience fund was formally established.",
            readerDocument: ReaderDocument(blocks: [
                ReaderBlock(kind: .paragraph, text: "A $100 billion annual climate resilience fund was formally established.")
            ])
        )

        let artBBC = FeedArticle(
            storedID: "art_bbc_summit",
            title: "Analysis: Inside the Geneva Climate Breakthrough",
            link: "https://bbc.invalid/climate-breakthrough",
            guid: "bbc-summit-01",
            description: "Behind the scenes of late-night plenary diplomacy.",
            pubDate: now.addingTimeInterval(-7200),
            source: "BBC News",
            fullContent: "Observers praised the swift resolution of contentious language.",
            readerDocument: ReaderDocument(blocks: [
                ReaderBlock(kind: .paragraph, text: "Observers praised the swift resolution of contentious language.")
            ])
        )

        let summitMembers: [FeedArticle] = [artAP, artReuters, artBBC]
        _ = try await db.upsertArticles(summitMembers, feedUrl: "https://liveqa.invalid/feed")
        let summitEvent = try await db.createEvent(memberArticleIDs: summitMembers.map { $0.id })

        let summitOverview = EventOverviewDocument(
            id: "overview_summit",
            eventID: summitEvent.id,
            version: OverviewVersionContext(
                membershipVersion: summitEvent.membershipVersion,
                inputTextHash: "summit_hash_01",
                schemaVersion: 1,
                analysisVersion: 2
            ),
            content: OverviewContent(
                title: "Global Climate Summit Adopts Geneva Pact",
                summary: "Delegates from 195 nations established a $100B resilience fund and binding carbon neutrality milestones.",
                facts: [
                    OverviewFact(id: "f1", text: "Delegates from 195 nations agreed to binding carbon neutrality milestones.", citationIDs: ["c1"]),
                    OverviewFact(id: "f2", text: "A $100 billion annual climate resilience fund was established.", citationIDs: ["c2"])
                ],
                citations: [
                    OverviewCitation(
                        id: "c1",
                        articleID: artAP.id,
                        passageID: "p1",
                        passageFingerprint: "fp1",
                        quote: "Delegates from 195 nations signed the treaty.",
                        source: OverviewSourceMetadata(title: artAP.title, name: artAP.source, url: artAP.link, publishedAt: artAP.pubDate)
                    ),
                    OverviewCitation(
                        id: "c2",
                        articleID: artReuters.id,
                        passageID: "p2",
                        passageFingerprint: "fp2",
                        quote: "A $100 billion annual climate resilience fund was formally established.",
                        source: OverviewSourceMetadata(title: artReuters.title, name: artReuters.source, url: artReuters.link, publishedAt: artReuters.pubDate)
                    )
                ],
                leadImage: nil, // Overview hero loading uses AsyncImage; keep this fixture offline.
                evidenceSections: OverviewEvidenceSections(
                    timeline: [
                        OverviewTimelineItem(dateText: "12 October", summary: "Working groups convened in Geneva", isFuturePlan: false),
                        OverviewTimelineItem(dateText: "15 October", summary: "Final treaty ratified unanimously", isFuturePlan: false)
                    ],
                    perspectives: [
                        OverviewPerspective(participant: "European Delegates", position: "European delegates pushed for enforceable mechanisms", sourcePublisher: "Reuters"),
                        OverviewPerspective(participant: "Developing Nations", position: "Developing nations secured dedicated loss-and-damage financing", sourcePublisher: "Associated Press")
                    ],
                    thematicAngle: OverviewThematicAngle(
                        title: "Economic Impact",
                        summary: "Economic implications of binding energy transition targets across developing economies."
                    )
                )
            ),
            provenance: OverviewProvenance(memberArticleIDs: summitMembers.map { $0.id }, kind: .synthesized)
        )

        _ = try await db.recordEventOverview(summitOverview)

        // 2. Structured Single-Source Article: Fusion Reactor
        let fusionArticle = FeedArticle(
            storedID: "art_fusion",
            title: "Next-Generation Fusion Reactor Exceeds Q-Threshold",
            link: "https://naturetech.invalid/fusion-q-threshold",
            guid: "nature-fusion-01",
            description: "High-temperature superconducting magnets achieve sustained confinement.",
            pubDate: now.addingTimeInterval(-10800),
            source: "Nature Technology",
            fullContent: "Scientists demonstrated net positive electrical energy output from a compact tokamak.",
            readerDocument: ReaderDocument(blocks: [
                ReaderBlock(kind: .paragraph, text: "Scientists today demonstrated net positive electrical energy output from a compact tokamak."),
                ReaderBlock(
                    kind: .figure,
                    text: "Cross-section of vacuum vessel",
                    imageURL: "https://liveqa.invalid/images/tokamak.jpg",
                    imageAlt: "Cross-section of vacuum vessel with superconducting coils",
                    imageCredit: "Plasma Lab",
                    imageWidth: 600,
                    imageHeight: 400
                ),
                ReaderBlock(kind: .heading, text: "Core Physics Breakthrough"),
                ReaderBlock(kind: .subheading, text: "Plasma Equilibrium State"),
                ReaderBlock(kind: .paragraph, text: "The magnetic confinement coils maintained high-density deuterium-tritium plasma."),
                ReaderBlock(kind: .quote, text: "The sustained reaction demonstrated net electrical gain for 1,000 seconds."),
                ReaderBlock(
                    kind: .figure,
                    text: "Toroidal field sensor array",
                    imageURL: "https://liveqa.invalid/images/sensor.jpg",
                    imageAlt: "", // Intentionally blank to test "Article image" fallback
                    imageCredit: "Diagnostics Team",
                    imageWidth: 400,
                    imageHeight: 300
                )
            ])
        )

        _ = try await db.upsertArticles([fusionArticle], feedUrl: "https://liveqa.invalid/feed")

        // 3. Realistic Single Article
        let singleArticle = FeedArticle(
            storedID: "art_markets",
            title: "Global Markets Rally on Technology Momentum",
            link: "https://ft.invalid/markets-rally",
            guid: "ft-markets-01",
            description: "Indices posted strong gains across European and Asian trading sessions.",
            pubDate: now.addingTimeInterval(-14400),
            source: "Financial Times",
            fullContent: "Indices posted strong gains across European and Asian trading sessions."
        )
        _ = try await db.upsertArticles([singleArticle], feedUrl: "https://liveqa.invalid/feed")

        // Mark all articles processed by matcher so feed grouping is ready
        let allIDs = [artAP.id, artReuters.id, artBBC.id, fusionArticle.id, singleArticle.id]
        try await db.markEventMatchProcessed(allIDs, matcherVersion: EventMatcher.version, at: now)

        _ = await store.refreshState()

        let manager = FeedManager(settings: settings, store: store, schedulesRefresh: false, fetchBatch: { _, _ in [] })
        await manager.waitForEventClustering()
        manager.articles = store.articles
        let themeManager = ThemeManager()
        let container = AppContainer(appSettings: settings, articleStore: store, feedManager: manager, themeManager: themeManager)

        state.container = container
        state.settings = settings
        state.store = store
        state.manager = manager
        state.fusionArticle = fusionArticle
        state.summitArticleAP = artAP
        state.summitArticleReuters = artReuters
        state.summitArticleBBC = artBBC
        state.summitOverview = summitOverview

        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1100, height: 800),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "News — VoiceOver Live QA"
        imageObserver = NotificationCenter.default.addObserver(forName: .readerImageFinished, object: nil, queue: .main) { [weak self] notification in
            guard let url = notification.object as? URL, notification.userInfo?["success"] as? Bool == true else { return }
            MainActor.assumeIsolated { _ = self?.loadedImages.insert(url) }
        }
        self.window = window
        try displayMode("LIST")

        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)

        print("HOST_READY \(ProcessInfo.processInfo.processIdentifier)")
        fflush(stdout)
    }

    func listen() throws {
        let channel = try LineChannel(FileHandle.standardInput)
        commandTask = Task {
            var status: Int32 = 0
            do {
                while !Task.isCancelled {
                    // An idle host may wait while the inspector traverses the tree, but never indefinitely.
                    let command = try await channel.nextLine(timeout: 90)
                    if command == "QUIT" { break }
                    try await handle(command)
                    print("CMD_DONE \(command)")
                    fflush(stdout)
                }
            } catch {
                fputs("QA host command failed: \(error)\n", stderr)
                status = 1
            }
            await shutdown()
            // The command host is disposable: exit after cleanup without AppKit termination/restoration.
            exit(status)
        }
    }

    func handle(_ command: String) async throws {
        switch command {
        case "MODE_READER": try displayMode("READER")
        case "MODE_OVERVIEW": try displayMode("OVERVIEW")
        case "MODE_LIST": try displayMode("LIST")
        case "HOLD_FEED":
            NotificationCenter.default.post(name: .nextArticleCommand, object: nil)
        case "QUEUE_UPDATES":
            guard let store = state.store else { throw QAFailure("Missing fixture store") }
            let incoming = (0..<3).map { index in
                FeedArticle(storedID: "qa-new-\(index)", title: "New fixture story \(index)",
                    link: "https://liveqa.invalid/new/\(index)", guid: "qa-new-\(index)",
                    description: "A distinct buffered fixture publication.",
                    pubDate: Date().addingTimeInterval(Double(index + 1)), source: "Fixture publisher \(index)")
            }
            _ = try await db.upsertArticles(incoming, feedUrl: "https://liveqa.invalid/feed")
            try await db.markEventMatchProcessed(incoming.map(\.id), matcherVersion: EventMatcher.version, at: Date())
            guard await store.refreshState() else { throw QAFailure("Could not publish fixture updates") }
        case "SCROLL_TOP", "SCROLL_MIDDLE", "SCROLL_BOTTOM":
            guard let content = window?.contentView, let scroll = Self.scrollView(in: content), let document = scroll.documentView else {
                throw QAFailure("Reader scroll view was not found")
            }
            let fraction: CGFloat = command == "SCROLL_TOP" ? 0 : command == "SCROLL_MIDDLE" ? 0.5 : 1
            let distance = max(0, document.bounds.height - scroll.contentView.bounds.height)
            let y = document.isFlipped ? distance * fraction : distance * (1 - fraction)
            scroll.contentView.scroll(to: CGPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        case "CHECK_READ":
            guard let article = state.fusionArticle else { throw QAFailure("Missing fixture article") }
            try await waitUntil("read action state") { self.state.container?.readManager.isRead(article.id) == true }
            guard state.container?.readManager.isRead(article.id) == true else {
                throw QAFailure("Accessibility read action did not update production read state")
            }
            try await waitUntil("read article persistence") { try await self.db.getReadArticleIDs().contains(article.id) }
        case "CHECK_SAVED":
            guard let article = state.fusionArticle else { throw QAFailure("Missing fixture article") }
            try await waitUntil("save action state") { self.state.container?.savedStories.isSaved(article) == true }
            guard state.container?.savedStories.isSaved(article) == true else {
                throw QAFailure("Accessibility save action did not update production save state")
            }
            // SavedStoriesManager's write is asynchronous; wait on observable persistence.
            try await waitUntil("saved article persistence") { try await self.db.getSavedArticles().contains { $0.id == article.id } }
        default: throw QAFailure("Unknown host command: \(command)")
        }
    }

    func displayMode(_ mode: String) throws {
        guard let window, let defaults else { throw QAFailure("Fixture host is not initialized") }
        // Separate fixtures get fresh native hosts; mutating a live NavigationSplitView into a
        // NavigationStack can leave SwiftUI accessibility nodes referring to a retired graph.
        window.contentView = nil
        loadedImages.removeAll()
        state.activeMode = mode
        let image = self.image
        let view = NSHostingView(rootView: HostRootView(state: state)
            .defaultAppStorage(defaults)
            .environment(\.readerImageLoader, { _ in image }))
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let scroll = scrollView(in: child) { return scroll }
        }
        return nil
    }

    func shutdown() async {
        state.manager?.stopBackgroundWork()
        if let imageObserver { NotificationCenter.default.removeObserver(imageObserver) }
        window?.orderOut(nil)
        window?.contentView = nil
        await db.close()
        defaults?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: tempDir)
    }

    func smoke(output: URL) async throws {
        for mode in ["LIST", "READER", "OVERVIEW"] {
            try displayMode(mode)
            if mode == "READER" {
                try await waitUntil("two fixture images decoded") { self.loadedImages.count >= 2 }
            }
            guard let view = window?.contentView else { throw QAFailure("No fixture window") }
            // Sampling a rendered bitmap is evidence for rendering, not accessibility traversal.
            try await Task.sleep(for: .milliseconds(300))
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw QAFailure("No fixture bitmap") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw QAFailure("Could not encode fixture bitmap") }
            try data.write(to: output.appendingPathComponent("\(mode.lowercased()).png"))
        }
        print("SMOKE_PASS: list, source reader, overview rendered; two offline images decoded")
    }
}

private func fixtureImage() throws -> CGImage {
    guard let context = CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw QAFailure("Could not create offline image")
    }
    context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.6, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
    guard let image = context.makeImage() else { throw QAFailure("Could not create offline image") }
    return image
}

struct QAFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

@MainActor
private func waitUntil(_ description: String, timeout: TimeInterval = 8, condition: () async throws -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while ProcessInfo.processInfo.systemUptime < deadline {
        try Task.checkCancellation()
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(25))
    }
    throw QAFailure("Timed out waiting for \(description)")
}

/// Nonblocking pipe reads keep AppKit's main run loop responsive; every wait has a monotonic deadline.
@MainActor
private final class LineChannel {
    let handle: FileHandle
    var pending = Data()
    init(_ handle: FileHandle) throws {
        self.handle = handle
        let flags = fcntl(handle.fileDescriptor, F_GETFL)
        guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw QAFailure("Could not configure nonblocking command pipe")
        }
    }

    func nextLine(timeout: TimeInterval = 8) async throws -> String {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var bytes = [UInt8](repeating: 0, count: 4096)
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            if let newline = pending.firstIndex(of: 10) {
                let line = String(decoding: pending[..<newline], as: UTF8.self)
                pending.removeSubrange(...newline)
                return line
            }
            let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
            if count > 0 {
                pending.append(contentsOf: bytes.prefix(count))
                guard pending.count <= 65536 else { throw QAFailure("Command pipe line exceeded 64 KiB") }
            } else if count == 0 {
                throw QAFailure("Command pipe closed before a complete response")
            } else if errno != EAGAIN && errno != EINTR {
                throw QAFailure("Command pipe read failed: \(errno)")
            } else {
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        throw QAFailure("Command pipe timed out after \(timeout) seconds")
    }

    func expect(_ response: String) async throws {
        let line = try await nextLine()
        guard line == response else { throw QAFailure("Expected \(response), received \(line)") }
    }
}

// MARK: - QA Test Runner & Inspector

@MainActor
final class LiveVoiceOverInspector {
    static var checksPassed = 0
    static var checksFailed = 0
    static var unavailableHeadingRanks = 0

    static func assert(_ condition: Bool, _ message: String) {
        if condition {
            checksPassed += 1
            print("  ✓ \(message)")
        } else {
            checksFailed += 1
            print("  ✗ FAILURE: \(message)")
        }
        fflush(stdout)
    }

    static func heading(_ records: [AXElementRecord], text: String, level: Int) -> AXElementRecord? {
        let record = records.first { $0.role == "AXHeading" && $0.spokenText.localizedCaseInsensitiveContains(text) }
        assert(record != nil, "Heading role is exposed for: \(text)")
        if let rank = record?.headingLevel {
            assert(rank == level, "Exported heading rank is H\(level): \(text)")
        } else if record != nil {
            unavailableHeadingRanks += 1
            print("  UNVERIFIED: H\(level) rank is not exported for \(text); check the VoiceOver rotor manually")
        }
        return record
    }

    static func run() async throws {
        print("=====================================================================")
        print("  Running Live VoiceOver QA Suite on Isolated Data (#155)")
        print("=====================================================================")

        guard AXIsProcessTrusted() else {
            throw QAFailure("Accessibility access is missing. Grant access to the terminal launching this QA bundle in System Settings > Privacy & Security > Accessibility, then rerun --live. Use --smoke for rendering checks or --manual for a spoken VoiceOver pass.")
        }
        // Apply a finite timeout to all AX messages issued by this process.
        guard AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.2) == .success else {
            throw QAFailure("Could not configure AX messaging timeout")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("news-vo-inspected-\(UUID().uuidString)")
        let suite = "test.vo.host.\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        proc.arguments = ["--host", "--fixture-directory", directory.path, "--defaults-suite", suite]
        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        let channel = try LineChannel(outPipe.fileHandleForReading)
        try proc.run()
        // Close parent copies so a crashed child produces EOF rather than an endless pipe wait.
        try outPipe.fileHandleForWriting.close()
        try inPipe.fileHandleForReading.close()
        defer {
            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            proc.waitUntilExit()
            try? inPipe.fileHandleForWriting.close()
            try? outPipe.fileHandleForReading.close()
        }
        let childPID = proc.processIdentifier
        func command(_ value: String) async throws {
            guard proc.isRunning else { throw QAFailure("QA host exited before \(value)") }
            try inPipe.fileHandleForWriting.write(contentsOf: Data("\(value)\n".utf8))
            try await channel.expect("CMD_DONE \(value)")
        }
        try await channel.expect("HOST_READY \(childPID)")
        let axApp = AXUIElementCreateApplication(childPID)
        var observer: AXObserver?
        let obsErr = AXObserverCreateWithInfoCallback(childPID, axObserverCallback, &observer)
        guard obsErr == .success, let observer else { throw QAFailure("Could not create AXObserver: \(obsErr.rawValue)") }
        let notification = kAXAnnouncementRequestedNotification as CFString
        let addErr = AXObserverAddNotification(observer, axApp, notification, nil)
        guard addErr == .success else {
            throw QAFailure("Cannot observe announcement notifications (AX error \(addErr.rawValue)). Start VoiceOver and rerun --live; a rendering smoke pass does not verify spoken announcements.")
        }
        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        defer {
            AXObserverRemoveNotification(observer, axApp, notification)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }

        func getWindow(timeout: TimeInterval = 6.0) async -> AXUIElement? {
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while ProcessInfo.processInfo.systemUptime < deadline {
                var windowsVal: AnyObject?
                if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsVal) == .success,
                   let windows = windowsVal as? [AXUIElement] {
                    for w in windows {
                        var roleVal: AnyObject?
                        AXUIElementCopyAttributeValue(w, kAXRoleAttribute as CFString, &roleVal)
                        if (roleVal as? String) == "AXWindow" {
                            var titleVal: AnyObject?
                            AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &titleVal)
                            let title = (titleVal as? String) ?? ""
                            if title.contains("VoiceOver Live QA") || title.contains("News") {
                                return w
                            }
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            return nil
        }

        func pollNavigationOrder(timeout: TimeInterval = 12.0, condition: ([AXElementRecord]) -> Bool) async throws -> [AXElementRecord] {
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            var lastOrder: [AXElementRecord] = []
            while ProcessInfo.processInfo.systemUptime < deadline {
                if let win = await getWindow(timeout: 1.0) {
                    let tree = try inspectAXElement(win)
                    let order = flattenNavigationOrder(tree)
                    lastOrder = order
                    if condition(order) {
                        return order
                    }
                }
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
            throw QAFailure("Expected accessibility state did not appear within \(timeout) seconds; last tree had \(lastOrder.count) elements")
        }

        func scanReader() async throws -> [AXElementRecord] {
            var records: [AXElementRecord] = []
            var seen: Set<String> = []
            for position in ["SCROLL_TOP", "SCROLL_MIDDLE", "SCROLL_BOTTOM"] {
                try await command(position)
                // Scroll layout is asynchronous; sample after the host processes a redraw.
                try await Task.sleep(for: .milliseconds(150))
                guard let window = await getWindow() else { throw QAFailure("Fixture window disappeared during scrolling") }
                for record in flattenNavigationOrder(try inspectAXElement(window)) {
                    let key = "\(record.role):\(record.spokenText):\(record.headingLevel ?? 0)"
                    if seen.insert(key).inserted { records.append(record) }
                }
            }
            try await command("SCROLL_TOP")
            return records
        }

        // -------------------------------------------------------------
        // SUITE 1: Feed & Event Card QA (MainView)
        // -------------------------------------------------------------
        print("\n--- [Suite 1/3] Feed List, Event Cards & Announcement QA ---")
        guard await getWindow() != nil else {
            throw QAFailure("Could not obtain fixture window AXUIElement within six seconds")
        }

        let order1 = try await pollNavigationOrder { order in
            order.contains { $0.spokenText.contains("Global Climate Summit") }
                && !order.contains { $0.spokenText.contains("Loading articles") }
        }

        print("\n  Recorded Feed AX Tree Order (\(order1.count) elements):")
        for (idx, el) in order1.enumerated() {
            let acts = el.customActions.isEmpty ? "" : " (Actions: \(el.customActions.joined(separator: ", ")))"
            print("    \(idx + 1). [\(el.role)] \"\(el.spokenText)\"\(acts)")
        }

        // 1. Sidebar checks
        let hasSidebarToday = order1.contains { $0.spokenText.contains("Today") }
        let hasSidebarUnread = order1.contains { $0.spokenText.contains("Unread") }
        let hasSidebarSaved = order1.contains { $0.spokenText.contains("Saved") }
        let hasSearchField = order1.contains { $0.role == "AXTextField" || $0.spokenText.contains("Search") }
        assert(hasSidebarToday && hasSidebarUnread && hasSidebarSaved, "Sidebar exposes primary navigation targets")
        assert(hasSearchField, "Sidebar exposes search field")

        // 2. Toolbar controls
        let hasCoverageToggle = order1.contains { $0.spokenText.contains("Group Coverage") }
        let hasRefresh = order1.contains { $0.spokenText.contains("Refresh") }
        assert(hasCoverageToggle, "Feed toolbar exposes 'Group Coverage by Event' toggle")
        assert(hasRefresh, "Feed toolbar exposes 'Refresh Feeds' action")

        // 3. Event Card & Single Card
        let eventCard = order1.first { $0.spokenText.contains("Global Climate Summit") }
        assert(eventCard != nil, "Feed displays multi-source event card")

        let singleCard = order1.first { $0.spokenText.contains("Next-Generation Fusion Reactor") }
        assert(singleCard != nil, "Feed displays structured single-source article card")

        // 4. Rotor Actions on Cards
        let singleCardActions = singleCard?.customActions ?? []
        let hasReadAction = singleCardActions.contains("Mark as Read") || singleCardActions.contains("Mark as Unread")
        let hasSaveAction = singleCardActions.contains("Save Story") || singleCardActions.contains("Remove from Saved")
        assert(hasReadAction, "Article card exposes 'Mark as Read' as accessibility actions")
        assert(hasSaveAction, "Article card exposes 'Save Story' as accessibility actions")

        guard let coverage = order1.first(where: { $0.spokenText.hasPrefix("Event:") && $0.actions.contains(kAXPressAction as String) })?.element,
              AXUIElementPerformAction(coverage, kAXPressAction as CFString) == .success else {
            throw QAFailure("Could not expand the event's coverage through accessibility")
        }
        let expanded = try await pollNavigationOrder { order in
            order.contains { $0.spokenText.contains("Geneva Conference Concludes") } && order.contains { $0.spokenText.contains("Analysis: Inside the Geneva") }
        }
        assert(expanded.contains { $0.customActions.contains("Not the Same Event") }, "Expanded event sources expose the separation action")
        guard AXUIElementPerformAction(coverage, kAXPressAction as CFString) == .success else { throw QAFailure("Could not collapse event coverage") }

        // Invoke the exposed actions and confirm production state plus SQLite persistence.
        func perform(_ record: AXElementRecord?, named name: String) throws {
            guard let element = record?.element else { throw QAFailure("Missing element for action \(name)") }
            var raw: CFArray?
            let copyError = AXUIElementCopyActionNames(element, &raw)
            guard copyError == .success else { throw QAFailure("Cannot read actions: \(copyError.rawValue)") }
            guard let action = (raw as? [String])?.first(where: {
                $0.components(separatedBy: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "Name: \(name)" || $0 == "Name:\(name)" }
            }) else { throw QAFailure("Missing accessibility action \(name)") }
            let result = AXUIElementPerformAction(element, action as CFString)
            guard result == .success else { throw QAFailure("Accessibility action \(name) failed: \(result.rawValue)") }
        }
        try perform(singleCard, named: "Mark as Read")
        try await command("CHECK_READ")
        assert(true, "Accessibility read action updated and persisted production read state")
        let updatedCards = try await pollNavigationOrder { $0.contains { $0.spokenText.contains("Next-Generation Fusion Reactor") } }
        try perform(updatedCards.first { $0.spokenText.contains("Next-Generation Fusion Reactor") }, named: "Save Story")
        try await command("CHECK_SAVED")
        assert(true, "Accessibility save action updated and persisted production save state")

        // Focus the feed through its production navigation command, then publish actual new rows.
        try await command("HOLD_FEED")
        try await command("QUEUE_UPDATES")
        try await waitUntil("production buffered-update announcement") {
            AnnouncementBox.shared.getAnnouncements().contains { $0.text == "3 new stories available" }
        }
        let announcement = AnnouncementBox.shared.getAnnouncements().last { $0.text == "3 new stories available" }
        assert(announcement?.priority == NSAccessibilityPriorityLevel.medium.rawValue,
            "Observed production buffered-update notification with medium priority (speech requires a manual pass)")

        // -------------------------------------------------------------
        // SUITE 2: Source Article Reader Mode QA
        // -------------------------------------------------------------
        print("\n--- [Suite 2/3] Source Article Reader Mode QA ---")
        try await command("MODE_READER")

        _ = try await pollNavigationOrder { $0.contains { $0.spokenText.contains("Next-Generation Fusion Reactor") } }
        let order2 = try await scanReader()

        print("\n  Recorded Reader AX Tree Order (\(order2.count) elements):")
        for (idx, el) in order2.enumerated() {
            let lvl = el.headingLevel.map { " (H\($0))" } ?? ""
            print("    \(idx + 1). [\(el.role)]\(lvl) \"\(el.spokenText)\"")
        }

        // 2. Grouped Source Line
        let sourceLine = order2.first { $0.spokenText.contains("Nature Technology") && $0.spokenText.contains("min read") }
        assert(sourceLine != nil, "Source metadata is combined into a single accessibility element")

        // 3. Headings Hierarchy
        let h1Article = heading(order2, text: "Next-Generation Fusion Reactor", level: 1)
        assert(h1Article?.spokenText.contains("Next-Generation Fusion Reactor") == true, "Heading text matches article title")
        _ = heading(order2, text: "Core Physics Breakthrough", level: 2)
        _ = heading(order2, text: "Plasma Equilibrium State", level: 3)

        // Non-headings do not have AXHeading
        let nonHeadingRoleCount = order2.filter { $0.role == "AXHeading" }.count
        assert(nonHeadingRoleCount == 3, "Only true headings (H1, H2, H3) possess AXHeading role (\(nonHeadingRoleCount) found)")

        // 4. Figures & Alt Text
        let leadFigure = order2.first { $0.spokenText == "Cross-section of vacuum vessel with superconducting coils" }
        assert(leadFigure != nil, "Lead image preserves explicit alt text in accessibility tree")

        let creditText = order2.first { $0.spokenText.contains("Image credit: Plasma Lab") }
        assert(creditText != nil, "Image credit is exposed as a separate accessibility element")

        let fallbackFigure = order2.first { $0.spokenText == "Article image" }
        assert(fallbackFigure != nil, "Figure with empty alt text correctly falls back to 'Article image'")

        // 5. Blockquote
        let quoteBlock = order2.first { $0.spokenText.contains("net electrical gain for 1,000 seconds") }
        assert(quoteBlock != nil, "Blockquote text is accessible without decorative bar interruption")

        // -------------------------------------------------------------
        // SUITE 3: Event Overview Reader Mode QA
        // -------------------------------------------------------------
        print("\n--- [Suite 3/3] Event Overview Reader Mode QA ---")
        try await command("MODE_OVERVIEW")

        _ = try await pollNavigationOrder { $0.contains { $0.spokenText.contains("Global Climate Summit Adopts Geneva Pact") } }
        var order3 = try await scanReader()

        print("\n  Recorded Overview AX Tree Order (\(order3.count) elements):")
        for (idx, el) in order3.enumerated() {
            let lvl = el.headingLevel.map { " (H\($0))" } ?? ""
            print("    \(idx + 1). [\(el.role)]\(lvl) \"\(el.spokenText)\"")
        }

        // Exercise the disclosure rather than injecting its expanded state into production views.
        if let sources = order3.first(where: { $0.spokenText.contains("Sources") && $0.actions.contains(kAXPressAction as String) }),
           let element = sources.element {
            _ = AXUIElementPerformAction(element, "AXScrollToVisible" as CFString)
            let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
            guard result == .success else { throw QAFailure("Sources disclosure action failed: \(result.rawValue)") }
            order3 = try await scanReader()
        }

        // 1. Overview Title (H1)
        let h1Overview = heading(order3, text: "Global Climate Summit Adopts Geneva Pact", level: 1)
        assert(h1Overview?.spokenText.contains("Global Climate Summit Adopts Geneva Pact") == true, "Overview heading matches expected title")

        // 2. Metadata line
        let metaLine = order3.first { $0.spokenText.contains("Updated") && $0.spokenText.contains("articles") && $0.spokenText.contains("publishers") }
        assert(metaLine != nil, "Overview metadata is combined into a single accessibility element")

        // 3. Section Headings (H2)
        for section in ["Key facts", "Timeline", "Perspectives", "Economic Impact", "Sources", "Original publications"] {
            _ = heading(order3, text: section, level: 2)
        }

        // 4. Citation Pills
        let citationPills = order3.filter { $0.role == "AXButton" && $0.spokenText.contains("Citation from") }
        assert(!citationPills.isEmpty, "Citation pills are accessible buttons with explicit source and quote")
        if let firstPill = citationPills.first {
            assert(firstPill.hint == "Opens source publication at cited passage", "Citation pill has explicit hint for navigation")
        }

        // 5. Contextual Source Buttons
        let readButtons = order3.filter { $0.spokenText.hasPrefix("Read ") && $0.spokenText.contains("in Source publication mode") }
        let webButtons = order3.filter { $0.spokenText.hasPrefix("Open original publication: ") }
        assert(!readButtons.isEmpty, "Sources section exposes distinct contextual Read button labels")
        assert(!webButtons.isEmpty, "Sources section exposes distinct contextual Open web button labels")

        // Follow a real citation, then dismiss its production banner through AXPress.
        guard let pill = citationPills.first, let pillElement = pill.element else { throw QAFailure("No citation pill to exercise") }
        _ = AXUIElementPerformAction(pillElement, "AXScrollToVisible" as CFString)
        guard AXUIElementPerformAction(pillElement, kAXPressAction as CFString) == .success else { throw QAFailure("Citation press failed") }
        let citedOrder = try await pollNavigationOrder { $0.contains { $0.spokenText.contains("Cited passage in event overview") } }
        assert(citedOrder.contains { $0.spokenText.contains("Delegates from 195 nations signed the treaty.") || $0.spokenText.contains("$100 billion annual") }, "Citation opens the source publication with its stored passage")
        guard let dismiss = citedOrder.first(where: { $0.spokenText == "Dismiss citation highlight" })?.element,
              AXUIElementPerformAction(dismiss, kAXPressAction as CFString) == .success else { throw QAFailure("Citation banner dismiss action failed") }
        let dismissed = try await pollNavigationOrder { !$0.contains { $0.spokenText.contains("Cited passage in event overview") } }
        assert(!dismissed.isEmpty && !dismissed.contains { $0.spokenText.contains("Cited passage in event overview") }, "Dismiss action removes the citation banner")
        try inPipe.fileHandleForWriting.write(contentsOf: Data("QUIT\n".utf8))
        try await waitUntil("QA host cleanup and exit", timeout: 5) { !proc.isRunning }
        guard proc.terminationStatus == 0 else { throw QAFailure("QA host failed during cleanup") }

        print("\n=====================================================================")
        print("  Live AX QA Summary: \(checksPassed) passed, \(checksFailed) failed; \(unavailableHeadingRanks) heading ranks unverified")
        print("  Spoken VoiceOver, cursor order and rotor traversal require a separate manual pass.")
        print("=====================================================================")

        if checksFailed > 0 {
            throw NSError(domain: "LiveVoiceOverQA", code: 1, userInfo: [NSLocalizedDescriptionKey: "VoiceOver QA checks failed"])
        }
    }
}

// MARK: - Main Entry Point

@MainActor
private func selfTest() async throws {
    let pipe = Pipe()
    let channel = try LineChannel(pipe.fileHandleForReading)
    try pipe.fileHandleForWriting.write(contentsOf: Data("HOST_".utf8))
    let writer = Task { @MainActor in
        try await Task.sleep(for: .milliseconds(25))
        try pipe.fileHandleForWriting.write(contentsOf: Data("READY\nCMD_DONE MODE_READER\n".utf8))
    }
    try await channel.expect("HOST_READY")
    try await channel.expect("CMD_DONE MODE_READER")
    try await writer.value
    try pipe.fileHandleForWriting.close()
    do { _ = try await channel.nextLine(); throw QAFailure("EOF check did not fail") }
    catch let error as QAFailure { guard error.description.contains("closed") else { throw error } }
    let idle = Pipe()
    let idleChannel = try LineChannel(idle.fileHandleForReading)
    let start = ProcessInfo.processInfo.systemUptime
    do { _ = try await idleChannel.nextLine(timeout: 0.05); throw QAFailure("Deadline check did not fail") }
    catch let error as QAFailure { guard error.description.contains("timed out") else { throw error } }
    guard ProcessInfo.processInfo.systemUptime - start < 1 else { throw QAFailure("Pipe deadline was not bounded") }
    let waiter = Task { try await idleChannel.nextLine() }
    waiter.cancel()
    do { _ = try await waiter.value; throw QAFailure("Cancellation did not stop the pipe wait") }
    catch is CancellationError { }
    try idle.fileHandleForWriting.write(contentsOf: Data("WRONG_ACK\n".utf8))
    do { try await idleChannel.expect("CMD_DONE MODE_READER"); throw QAFailure("Wrong acknowledgement was accepted") }
    catch let error as QAFailure { guard error.description.contains("Expected") else { throw error } }
    guard try fixtureImage().width == 120 else { throw QAFailure("Invalid offline fixture image") }
    print("SELF_TEST_PASS: partial reads, multiple responses, EOF, deadline, cancellation, wrong acknowledgement, offline image")
}

@MainActor
private final class QADelegate: NSObject, NSApplicationDelegate {
    var host: LiveVoiceOverHost?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do {
                if CommandLine.arguments.contains("--self-test") {
                    try await selfTest()
                } else if CommandLine.arguments.contains("--host") || CommandLine.arguments.contains("--manual") || CommandLine.arguments.contains("--smoke") {
                    let host = try LiveVoiceOverHost()
                    self.host = host
                    try await host.run()
                    if CommandLine.arguments.contains("--host") {
                        try host.listen()
                        return
                    }
                    if CommandLine.arguments.contains("--manual") {
                        installFixtureMenu()
                        print("Manual pass: enable VoiceOver; traverse sidebar/cards; use headings/actions rotor; read/save a card; expand event sources; open overview; follow/dismiss a citation. Use the Fixtures menu (Command-1/2/3) for list/source/overview and Queue New Stories for buffered updates. Close the fixture window to finish. Real library and installed app are untouched.")
                        return
                    }
                    guard let outputPath = ProcessInfo.processInfo.environment["NEWS_VOICEOVER_OUTPUT"] else { throw QAFailure("Missing smoke output directory") }
                    try await host.smoke(output: URL(fileURLWithPath: outputPath))
                    await host.shutdown()
                    self.host = nil
                } else {
                    try await LiveVoiceOverInspector.run()
                }
                NSApplication.shared.terminate(nil)
            } catch {
                if let host { await host.shutdown() }
                fputs("VoiceOver QA failed: \(error)\n", stderr)
                exit(1)
            }
        }
    }

    private func installFixtureMenu() {
        let main = NSMenu()
        let fixtures = NSMenu(title: "Fixtures")
        let root = NSMenuItem(title: "Fixtures", action: nil, keyEquivalent: "")
        root.submenu = fixtures
        main.addItem(root)
        for (title, action, key) in [("Feed", #selector(showFeed), "1"), ("Source Reader", #selector(showSource), "2"),
                                     ("Event Overview", #selector(showOverview), "3"), ("Queue New Stories", #selector(queueUpdates), "u")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            fixtures.addItem(item)
        }
        NSApplication.shared.mainMenu = main
    }

    @objc private func showFeed() { showMode("LIST") }
    @objc private func showSource() { showMode("READER") }
    @objc private func showOverview() { showMode("OVERVIEW") }
    private func showMode(_ mode: String) {
        do { try host?.displayMode(mode) }
        catch { fputs("Fixture mode failed: \(error)\n", stderr) }
    }

    @objc private func queueUpdates() {
        Task {
            do {
                try await host?.handle("HOLD_FEED")
                try await host?.handle("QUEUE_UPDATES")
            } catch { fputs("Fixture update failed: \(error)\n", stderr) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let host else { return .terminateNow }
        self.host = nil
        Task {
            host.commandTask?.cancel()
            await host.shutdown()
            exit(0)
        }
        return .terminateLater
    }
}

@main
struct LiveVoiceOverEntry {
    @MainActor
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        // Crash recovery dialogs must never block this disposable fixture's startup.
        // Argument-domain overrides are volatile and do not change the reader's real preferences.
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["ApplePersistenceIgnoreState"] = true
        arguments["NSQuitAlwaysKeepsWindows"] = false
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        let app = NSApplication.shared
        let delegate = QADelegate()
        app.delegate = delegate
        let visible = CommandLine.arguments.contains("--host") || CommandLine.arguments.contains("--manual") || CommandLine.arguments.contains("--smoke")
        app.setActivationPolicy(visible ? .regular : .prohibited)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
