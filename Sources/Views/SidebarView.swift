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
    /// Panel collection is on, so the sidebar foot shows the news tension reading.
    var showsTensionReading = false
    var tension = WorldTensionState()
    var openTension: () -> Void = {
        // Default no-op action
    }

    @EnvironmentObject private var appSettings: AppSettings
    @EnvironmentObject private var feedManager: FeedManager
    @EnvironmentObject private var savedStories: SavedStoriesManager
    @EnvironmentObject private var readManager: ReadManager
    @Environment(\.effectiveReduceMotion) private var reduceMotion

    @State private var isSubscribePopoverPresented = false
    @State private var newFeedURL: String = ""
    @State private var isDropTargeted = false
    @State private var pendingSectionRemoval: String?
    /// On macOS 27 a row click does not keep keyboard focus in the sidebar once the window title and toolbar
    /// search update for the new section, so arrow keys reached the story list instead.
    @FocusState private var isListFocused: Bool

    var body: some View {
        List(
            selection: Binding(
                get: { selectedTopic ?? "Today" },
                set: { newTopic in
                    if let newTopic = newTopic {
                        selectedTopic = newTopic
                        // Only clicks and arrow keys in the list reach this setter; ⌘1–⌘4 leave focus alone.
                        isListFocused = true
                    }
                }
            )
        ) {
            inboxSection
            librarySection
            userSectionsSection
        }
        .focused($isListFocused)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsTensionReading {
                VStack(spacing: 0) {
                    Divider()
                    TensionSidebarButton(state: tension, open: openTension)
                        .padding(.horizontal, AppLayout.sidebarInset)
                        .padding(.vertical, AppSpacing.xs)
                }
            }
        }
        .focusedSceneValue(\.addFeedSubscription, { isSubscribePopoverPresented = true })
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isSubscribePopoverPresented = true
                } label: {
                    Label("Add Feed", systemImage: "plus")
                }
                .help("Add a feed")
                .accessibilityLabel("Add Feed")
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
                .animation(reduceMotion ? nil : AppMotion.hover, value: isDropTargeted)
        )
    }

    // MARK: - Sidebar Sections

    /// A native sidebar row (DESIGN.md 6): the list's selection handles clicks and arrow keys, the system draws
    /// the badge, and row size follows the person's sidebar size setting.
    @ViewBuilder
    private func topicRow(title: String, icon: String, badge: Int? = nil, isLoading: Bool = false) -> some View {
        let count = badge ?? 0
        let badgeValue = count > 0 ? String(count) : ""
        // The filled variant marks the selected row only, as Mail and Notes do.
        Label(title, systemImage: icon.replacingOccurrences(of: ".fill", with: ""))
            .symbolVariant((selectedTopic ?? "Today") == title ? .fill : .none)
            .badge(badge ?? 0)
            .overlay(alignment: .trailing) {
                if isLoading { ProgressView().controlSize(.mini) }
            }
            .symbolRenderingMode(.monochrome)
            .transaction { $0.animation = nil }
            // The list reports only selection changes; a click on the selected row still returns to its list.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { selectedTopic = title })
            .tag(title)
            .accessibilityValue(isLoading ? "Refreshing" : badgeValue)
    }

    private var inboxSection: some View {
        Section("Inbox") {
            topicRow(title: "Today", icon: "newspaper", isLoading: feedManager.isAnyFeedLoading)
            topicRow(title: "Unread", icon: "circle.circle", badge: unreadBadge)
            topicRow(title: "Briefing", icon: "text.book.closed")
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
                title: "Saved Stories", icon: "bookmark", badge: savedStories.savedArticles.count)
            topicRow(title: "History", icon: "clock")
        }
    }

    private var userSectionsSection: some View {
        Section("Sections") {
            ForEach(feedManager.userSections, id: \.self) { section in
                topicRow(title: section, icon: iconForSection(section))
                    .contextMenu {
                        Button(role: .destructive) {
                            pendingSectionRemoval = section
                        } label: {
                            Label("Remove Section", systemImage: "minus.circle")
                        }
                    }
            }
        }
        .confirmationDialog(
            "Remove the section “\(pendingSectionRemoval ?? "")”?",
            isPresented: Binding(
                get: { pendingSectionRemoval != nil }, set: { if !$0 { pendingSectionRemoval = nil } }),
            presenting: pendingSectionRemoval
        ) { section in
            Button("Remove Section", role: .destructive) { feedManager.removeSection(section) }
        } message: { _ in
            Text("Stories stay in your library; only the sidebar entry goes.")
        }
    }

    // MARK: - Popover

    private var subscribePopover: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Add Feed")
                .font(AppTypography.sectionTitle)

            TextField("Feed URL", text: $newFeedURL)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit(addFromPopover)

            HStack {
                Spacer()
                Button("Cancel") {
                    isSubscribePopoverPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Add", action: addFromPopover)
                    .buttonStyle(.borderedProminent)
                    .tint(AppColor.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newFeedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
    }

    private func addFromPopover() {
        let trimmed = newFeedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        subscribe(to: trimmed)
        newFeedURL = ""
        isSubscribePopoverPresented = false
    }

    // MARK: - Drag and Drop Handling

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            // Check for File URL (e.g. OPML / XML file)
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { item, _ in
                    guard let url = item else {
                        Task { @MainActor in
                            self.feedManager.articleStore.operationError = "The dropped item could not be read."
                        }
                        return
                    }

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
                    } else {
                        Task { @MainActor in
                            self.feedManager.articleStore.operationError = "Drop an OPML file or an HTTP(S) feed URL."
                        }
                    }
                }
                return true
            }

            // Check for Plain Text URL
            if provider.canLoadObject(ofClass: NSString.self) {
                _ = provider.loadObject(ofClass: NSString.self) { item, _ in
                    guard let nsString = item as? NSString else {
                        Task { @MainActor in
                            self.feedManager.articleStore.operationError = "The dropped text could not be read."
                        }
                        return
                    }
                    let text = String(nsString).trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.hasPrefix("http://") || text.hasPrefix("https://") {
                        Task { @MainActor in
                            self.subscribe(to: text)
                        }
                    } else {
                        Task { @MainActor in
                            self.feedManager.articleStore.operationError =
                                "The dropped text is not an HTTP(S) feed URL."
                        }
                    }
                }
                return true
            }
        }
        return false
    }

    private func subscribe(to urlString: String) {
        if feedManager.addFeed(url: urlString) {
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
