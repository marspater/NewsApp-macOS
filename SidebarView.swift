// SidebarView.swift
// NewsApp Sidebar Navigation & Subscription Management

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SidebarView: View {
    @Binding var selectedTopic: String?
    @Binding var searchText: String
    
    @EnvironmentObject private var appSettings: AppSettings
    @EnvironmentObject private var feedManager: FeedManager
    @EnvironmentObject private var savedStories: SavedStoriesManager
    @EnvironmentObject private var readManager: ReadManager
    
    @State private var isSubscribePopoverPresented = false
    @State private var newFeedURL: String = ""
    @State private var isDropTargeted = false
    @State private var dropConfirmationMessage: String? = nil
    @State private var isSearchSyntaxHelpPresented = false
    @FocusState private var isSearchFocused: Bool
    
    private let suggestedTopics: [(String, String)] = [
        ("Entertainment", "tv"), ("Science", "atom"),
        ("U.S. Politics", "building.columns"), ("Tech", "cpu"),
        ("Business", "briefcase"), ("Health & Wellness", "leaf"),
        ("Fashion", "tshirt"), ("Travel", "airplane"),
        ("Sports", "sportscourt"), ("World", "globe.americas")
    ]
    
    var body: some View {
        List(selection: Binding(
            get: { selectedTopic ?? "Today" },
            set: { newTopic in
                if let newTopic = newTopic {
                    selectedTopic = newTopic
                }
                isSearchFocused = false
            }
        )) {
            searchFieldRow
            
            if let confirmation = dropConfirmationMessage {
                dropConfirmationBanner(confirmation)
            }
            
            inboxSection
            librarySection
            userSectionsSection
            suggestedSection
        }
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
                .animation(AppMotion.quick, value: isDropTargeted)
        )
    }
    
    // MARK: - Search Field
    
    private var searchFieldRow: some View {
        HStack(spacing: AppSpacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(AppColor.secondaryText)
                .font(.system(size: 13))
            
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .font(AppTypography.bodySmall)
                .focused($isSearchFocused)
                .onSubmit { isSearchFocused = false }
                .accessibilityLabel("Search articles")
            
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    isSearchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(AppColor.tertiaryText)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search text")
            }
            
            Button {
                isSearchSyntaxHelpPresented.toggle()
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 12))
                    .foregroundColor(AppColor.tertiaryText)
            }
            .buttonStyle(.plain)
            .help("Search Syntax & Filter Operators")
            .accessibilityLabel("Search Syntax Help")
            .popover(isPresented: $isSearchSyntaxHelpPresented) {
                searchSyntaxHelpView
            }
        }
        .padding(.horizontal, AppSpacing.xs)
        .padding(.vertical, 6)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.control)
                .stroke(AppColor.borderSubtle, lineWidth: 1)
        )
        .cornerRadius(AppRadius.control)
        .padding(.bottom, 6)
        .onExitCommand { isSearchFocused = false }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
    
    private var searchSyntaxHelpView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Search Filters")
                .font(AppTypography.headline)
                .foregroundColor(AppColor.primaryText)
                .padding(.bottom, 2)
            
            Group {
                syntaxHelpRow("is:unread", "Show unread articles only")
                syntaxHelpRow("is:read", "Show read articles only")
                syntaxHelpRow("is:saved", "Show bookmarked articles")
                syntaxHelpRow("source:<name>", "Filter by feed source name")
                syntaxHelpRow("category:<topic>", "Filter by article category")
            }
        }
        .padding(12)
        .frame(width: 250)
    }
    
    private func syntaxHelpRow(_ syntax: String, _ desc: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(syntax)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(AppColor.accent)
            Text(desc)
                .font(AppTypography.caption)
                .foregroundColor(AppColor.secondaryText)
        }
    }
    
    // MARK: - Drop Confirmation Banner
    
    private func dropConfirmationBanner(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(AppColor.success)
            Text(text)
                .font(AppTypography.caption)
                .foregroundColor(AppColor.primaryText)
                .lineLimit(1)
        }
        .padding(AppSpacing.xs)
        .background(AppColor.success.opacity(0.12))
        .cornerRadius(AppRadius.control)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
    
    // MARK: - Sidebar Sections
    
    private func topicRow(title: String, icon: String, badge: Int? = nil, isLoading: Bool = false, accessibility: String? = nil) -> some View {
        Button {
            selectedTopic = title
            isSearchFocused = false
        } label: {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 14, height: 14)
                } else if let b = badge, b > 0 {
                    Text("\(b)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(selectedTopic == title ? AppColor.primaryText : AppColor.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(selectedTopic == title ? AppColor.surface.opacity(0.8) : AppColor.surface))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tag(title)
        .accessibilityLabel(accessibility ?? title)
    }

    private var inboxSection: some View {
        Section("Inbox") {
            topicRow(title: "Today", icon: "newspaper.fill", isLoading: feedManager.isAnyFeedLoading, accessibility: "Today's Articles")
            topicRow(title: "Unread", icon: "circle.circle.fill", badge: feedManager.articles.filter { !readManager.isRead($0.id) }.count, accessibility: "Unread Articles")
        }
    }
    
    private var librarySection: some View {
        Section("Library") {
            topicRow(title: "Saved Stories", icon: "bookmark.fill", badge: savedStories.savedArticles.count, accessibility: "Saved Stories")
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
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(AppColor.tertiaryText)
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
                        feedManager.addFeed(url: trimmed)
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
                    
                    if url.isFileURL && (url.pathExtension.lowercased() == "opml" || url.pathExtension.lowercased() == "xml") {
                        if let fileData = try? Data(contentsOf: url) {
                            Task { @MainActor in
                                let countBefore = self.feedManager.feedURLs.count
                                self.feedManager.importFeeds(from: fileData)
                                let added = self.feedManager.feedURLs.count - countBefore
                                self.showConfirmation(added > 0 ? "Imported \(added) feed(s) from OPML" : "OPML feeds up to date")
                            }
                        }
                    } else if !url.isFileURL && (url.scheme == "http" || url.scheme == "https") {
                        let urlString = url.absoluteString
                        Task { @MainActor in
                            self.feedManager.addFeed(url: urlString)
                            self.showConfirmation("Subscribed to \(url.host ?? urlString)")
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
                            self.feedManager.addFeed(url: text)
                            self.showConfirmation("Subscribed to feed")
                        }
                    }
                }
                return true
            }
        }
        return false
    }
    
    private func showConfirmation(_ message: String) {
        withAnimation(AppMotion.responsive) {
            dropConfirmationMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            withAnimation(AppMotion.responsive) {
                self.dropConfirmationMessage = nil
            }
        }
    }
    
    private func iconForSection(_ section: String) -> String {
        let map: [String: String] = [
            "Entertainment": "tv", "Politics": "building.columns",
            "Business": "briefcase", "Tech": "cpu",
            "Food": "fork.knife", "Health & Wellness": "leaf",
            "Lifestyle": "chair.lounge", "Science": "atom",
            "U.S. Politics": "building.columns", "Fashion": "tshirt",
            "Travel": "airplane", "Sports": "sportscourt",
            "World": "globe.americas"
        ]
        return map[section] ?? "doc.text"
    }
}
