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
    
    private let suggestedTopics: [(String, String)] = [
        ("Entertainment", "tv"), ("Science", "atom"),
        ("U.S. Politics", "building.columns"), ("Tech", "cpu"),
        ("Business", "briefcase"), ("Health & Wellness", "leaf"),
        ("Fashion", "tshirt"), ("Travel", "airplane"),
        ("Sports", "sportscourt"), ("World", "globe.americas")
    ]
    
    var body: some View {
        List(selection: $selectedTopic) {
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
            RoundedRectangle(cornerRadius: AppRadius.medium)
                .stroke(isDropTargeted ? AppColor.accentPink : Color.clear, lineWidth: 2)
                .padding(AppSpacing.xxs)
                .animation(AppMotion.quick, value: isDropTargeted)
        )
    }
    
    // MARK: - Search Field
    
    private var searchFieldRow: some View {
        HStack(spacing: AppSpacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(AppColor.textTertiary)
                .font(.system(size: 13))
            
            TextField("Search articles (e.g. is:unread)", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .accessibilityLabel("Search articles")
            
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(AppColor.textTertiary)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search text")
            }
        }
        .padding(AppSpacing.xs)
        .background(AppColor.badgeBackground)
        .cornerRadius(AppRadius.medium)
        .padding(.bottom, 6)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
    
    // MARK: - Drop Confirmation Banner
    
    private func dropConfirmationBanner(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(AppColor.successGreen)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(AppColor.textPrimary)
                .lineLimit(1)
        }
        .padding(AppSpacing.xs)
        .background(AppColor.successGreen.opacity(0.12))
        .cornerRadius(AppRadius.small)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
    
    // MARK: - Sidebar Sections
    
    private var inboxSection: some View {
        Section("Inbox") {
            NavigationLink(value: "Today") {
                HStack {
                    Label("Today", systemImage: "newspaper.fill")
                    Spacer()
                    if feedManager.isAnyFeedLoading {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                            .frame(width: 14, height: 14)
                    }
                }
            }
            .accessibilityLabel("Today's Articles")
            .listRowBackground(
                selectedTopic == "Today" ? AnyView(AppColor.accentPink.opacity(0.8).cornerRadius(AppRadius.medium)) : AnyView(Color.clear)
            )
            
            NavigationLink(value: "Unread") {
                Label("Unread", systemImage: "circle.circle.fill")
            }
            .badge(feedManager.articles.filter { !readManager.isRead($0.id) }.count)
            .accessibilityLabel("Unread Articles")
            .listRowBackground(
                selectedTopic == "Unread" ? AnyView(AppColor.accentPink.opacity(0.8).cornerRadius(AppRadius.medium)) : AnyView(Color.clear)
            )
        }
    }
    
    private var librarySection: some View {
        Section("Library") {
            NavigationLink(value: "Saved Stories") {
                Label("Saved Stories", systemImage: "bookmark.fill")
            }
            .badge(savedStories.savedArticles.isEmpty ? 0 : savedStories.savedArticles.count)
            .accessibilityLabel("Saved Stories")
            
            NavigationLink(value: "History") {
                Label("History", systemImage: "clock.fill")
            }
            .accessibilityLabel("Reading History")
        }
    }
    
    private var userSectionsSection: some View {
        Section("Sections") {
            ForEach(feedManager.userSections, id: \.self) { section in
                NavigationLink(value: section) {
                    Label(section, systemImage: iconForSection(section))
                }
                .contextMenu {
                    Button(role: .destructive) {
                        feedManager.removeSection(section)
                    } label: {
                        Label("Remove Section", systemImage: "minus.circle")
                    }
                }
                .accessibilityLabel("Section \(section)")
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
                            Spacer()
                            Image(systemName: "plus.circle")
                                .foregroundColor(AppColor.textTertiary)
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
                .font(.headline)
            
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
                .tint(AppColor.accentPink)
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
