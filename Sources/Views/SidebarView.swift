// SidebarView.swift
// NewsApp Sidebar Navigation & Subscription Management

import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct AddFeedSubscriptionKey: FocusedValueKey { typealias Value = () -> Void }

extension FocusedValues {
    var addFeedSubscription: (() -> Void)? {
        get { self[AddFeedSubscriptionKey.self] }
        set { self[AddFeedSubscriptionKey.self] = newValue }
    }
}

struct SidebarView: View {
    @Binding var selectedTopic: String?
    @Binding var mastheadNotice: MastheadNotice?

    @EnvironmentObject private var appSettings: AppSettings
    @EnvironmentObject private var feedManager: FeedManager
    @EnvironmentObject private var savedStories: SavedStoriesManager
    @EnvironmentObject private var readManager: ReadManager
    @Environment(\.effectiveReduceMotion) private var reduceMotion

    @State private var isSubscribePopoverPresented = false
    @State private var newFeedURL: String = ""
    @State private var isDropTargeted = false

    private let suggestedTopics: [(String, String)] = [
        ("Entertainment", "tv"), ("Science", "atom"),
        ("U.S. Politics", "building.columns"), ("Tech", "cpu"),
        ("Business", "briefcase"), ("Health & Wellness", "leaf"),
        ("Fashion", "tshirt"), ("Travel", "airplane"),
        ("Sports", "sportscourt"), ("World", "globe.americas"),
    ]

    var body: some View {
        List(
            selection: Binding(
                get: { selectedTopic ?? "Today" },
                set: { newTopic in
                    if let newTopic = newTopic {
                        selectedTopic = newTopic
                    }
                }
            )
        ) {
            inboxSection
            librarySection
            userSectionsSection
            suggestedSection
        }
        .focusedSceneValue(\.addFeedSubscription, { isSubscribePopoverPresented = true })
        .listStyle(.sidebar)
        .scrollContentBackground(.visible)
        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isSubscribePopoverPresented = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add New Feed Subscription")
                .accessibilityLabel("Add Feed Subscription")
                .popover(isPresented: $isSubscribePopoverPresented) {
                    subscribePopover
                }
            }
        }
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.control)
                .stroke(isDropTargeted ? AppColor.accent : Color.clear, lineWidth: 1.5)
                .padding(AppSpacing.xxs)
                .animation(reduceMotion ? nil : AppMotion.quick, value: isDropTargeted)
        )
    }

    // MARK: - Sidebar Sections

    /// A native sidebar row (DESIGN.md 6): the list's selection handles clicks and arrow keys, the system draws
    /// the badge, and row size follows the person's sidebar size setting.
    @ViewBuilder
    private func topicRow(
        title: String, icon: String, badge: Int? = nil, isLoading: Bool = false, accessibility: String? = nil
    ) -> some View {
        let count = badge ?? 0
        let badgeValue = count > 0 ? String(count) : ""
        Group {
            if isLoading {
                HStack {
                    Label(title, systemImage: icon)
                    Spacer()
                    ProgressView()
                        .controlSize(.mini)
                }
            } else {
                Label(title, systemImage: icon)
                    .badge(badge ?? 0)
            }
        }
        .tag(title)
        .accessibilityLabel(accessibility ?? title)
        .accessibilityValue(isLoading ? "Refreshing" : badgeValue)
    }

    private var inboxSection: some View {
        Section("Inbox") {
            topicRow(
                title: "Today", icon: "newspaper.fill", isLoading: feedManager.isAnyFeedLoading,
                accessibility: "Today's Articles")
            topicRow(title: "Unread", icon: "circle.circle.fill", badge: unreadBadge, accessibility: "Unread Articles")
            topicRow(title: "Briefing", icon: "text.book.closed", accessibility: "Finite Briefing")
        }
    }

    /// Unread stories the Unread list can show: muted stories are left out, as they are from the list.
    private var unreadBadge: Int {
        let muting = appSettings.muteRules
        return feedManager.articles.filter { !readManager.isRead($0.id) && (muting.isEmpty || !muting.mutes($0)) }.count
    }

    private var librarySection: some View {
        Section("Library") {
            topicRow(
                title: "Saved Stories", icon: "bookmark.fill", badge: savedStories.savedArticles.count,
                accessibility: "Saved Stories")
            topicRow(title: "History", icon: "clock.fill", accessibility: "Reading History")
        }
    }

    private var userSectionsSection: some View {
        Section("Sections") {
            ForEach(feedManager.userSections, id: \.self) { section in
                topicRow(title: section, icon: iconForSection(section), accessibility: "Section \(section)")
                    .contextMenu {
                        Button(role: .destructive) {
                            feedManager.removeSection(section)
                        } label: {
                            Label("Remove Section", systemImage: "minus.circle")
                        }
                    }
            }
        }
    }

    private var suggestedSection: some View {
        Section("Suggested") {
            ForEach(suggestedTopics, id: \.0) { topic, icon in
                if !feedManager.userSections.contains(topic) {
                    Button {
                        feedManager.addSection(topic)
                    } label: {
                        HStack {
                            Label(topic, systemImage: icon)
                                .foregroundColor(AppColor.secondaryText)
                            Spacer()
                            Image(systemName: "plus")
                                .imageScale(.small)
                                .foregroundStyle(AppColor.tertiaryText)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add \(topic) to sections")
                }
            }
        }
    }

    // MARK: - Popover

    private var subscribePopover: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Subscribe to RSS Feed")
                .font(AppTypography.headline)

            TextField("https://example.com/feed.xml", text: $newFeedURL)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)

            HStack {
                Spacer()
                Button("Cancel") {
                    isSubscribePopoverPresented = false
                }

                Button("Add") {
                    let trimmed = newFeedURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        subscribe(to: trimmed)
                        newFeedURL = ""
                        isSubscribePopoverPresented = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColor.accent)
            }
        }
        .padding()
    }

    // MARK: - Drag and Drop Handling

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            // Check for File URL (e.g. OPML / XML file)
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { item, _ in
                    guard let url = item else { return }

                    if url.isFileURL
                        && (url.pathExtension.lowercased() == "opml" || url.pathExtension.lowercased() == "xml")
                    {
                        Task { @MainActor in
                            let added = await self.feedManager.importFeeds(fromFile: url)
                            if added > 0 {
                                self.showConfirmation("Imported \(added) feed\(added == 1 ? "" : "s") from OPML")
                            } else if self.feedManager.articleStore.operationError == nil {
                                self.showConfirmation("No new feeds imported")
                            }
                        }
                    } else if !url.isFileURL && (url.scheme == "http" || url.scheme == "https") {
                        let urlString = url.absoluteString
                        Task { @MainActor in
                            self.subscribe(to: urlString)
                        }
                    }
                }
                return true
            }

            // Check for Plain Text URL
            if provider.canLoadObject(ofClass: NSString.self) {
                _ = provider.loadObject(ofClass: NSString.self) { item, _ in
                    guard let nsString = item as? NSString else { return }
                    let text = String(nsString).trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.hasPrefix("http://") || text.hasPrefix("https://") {
                        Task { @MainActor in
                            self.subscribe(to: text)
                        }
                    }
                }
                return true
            }
        }
        return false
    }

    private func subscribe(to urlString: String) {
        let previousCount = feedManager.feedURLs.count
        feedManager.addFeed(url: urlString)
        if feedManager.feedURLs.count > previousCount {
            showConfirmation("Subscribed to \(URL(string: urlString)?.host ?? "feed")")
        } else {
            feedManager.articleStore.operationError = "Feed not added. Check the URL or whether you already subscribe."
        }
    }

    private func showConfirmation(_ message: String) {
        mastheadNotice = MastheadNotice(message: message)
    }

    private func iconForSection(_ section: String) -> String {
        let map: [String: String] = [
            "Entertainment": "tv", "Politics": "building.columns",
            "Business": "briefcase", "Tech": "cpu",
            "Food": "fork.knife", "Health & Wellness": "leaf",
            "Lifestyle": "chair.lounge", "Science": "atom",
            "U.S. Politics": "building.columns", "Fashion": "tshirt",
            "Travel": "airplane", "Sports": "sportscourt",
            "World": "globe.americas",
        ]
        return map[section] ?? "doc.text"
    }
}
