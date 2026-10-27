import SwiftUI

/// Opt-in browser for the curated starter catalog. Nothing is subscribed until the user chooses it.
struct FeedCatalogView: View {
    static let navigationTitleText = "Feed Catalog"
    static let showsDoneInToolbar = true
    static let hasBottomDoneBar = false
    static let hasCustomSheetBackground = false

    @EnvironmentObject private var appSettings: AppSettings
    @EnvironmentObject private var feedManager: FeedManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.effectiveContrast) private var contrast

    @State private var searchText = ""
    @State private var selectedSet: CatalogSet? = nil

    private var displayedSets: [CatalogSet] {
        if let selectedSet {
            return [selectedSet]
        }
        return CatalogSet.offered
    }

    private func matchingFeeds(in set: CatalogSet) -> [CatalogFeed] {
        let feeds = FeedCatalog.feeds(in: set)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return feeds }
        return feeds.filter { feed in
            feed.title.lowercased().contains(query)
                || feed.publisher.lowercased().contains(query)
                || feed.topic.rawValue.lowercased().contains(query)
                || feed.region.lowercased().contains(query)
        }
    }

    private var allMatchingFeedsCount: Int {
        displayedSets.reduce(0) { $0 + matchingFeeds(in: $1).count }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text("Feed Catalog")
                    .font(AppTypography.title)
                    .foregroundStyle(AppColor.primaryText)
                    .accessibilityAddTraits(.isHeader)

                Text(
                    "Explore verified, non-paywalled publications across world news, technology, science, and culture."
                )
                .font(AppTypography.callout)
                .foregroundStyle(AppColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppLayout.pageInset)
            .padding(.top, AppLayout.pageInset)
            .padding(.bottom, AppSpacing.xs)

            // Nine topics do not fit a segmented control; a menu reaches every one by pointer and keyboard (#600).
            Picker("Topic", selection: $selectedSet) {
                Text("All Topics").tag(CatalogSet?.none)
                ForEach(CatalogSet.offered) { topicSet in
                    Text(topicSet.title).tag(CatalogSet?.some(topicSet))
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppLayout.pageInset)
            .padding(.vertical, AppSpacing.xs)

            Divider()

            // Feed Content List
            if allMatchingFeedsCount == 0 && !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if allMatchingFeedsCount == 0 {
                ContentUnavailableView(
                    "No Feeds in This Topic", systemImage: "newspaper",
                    description: Text("The catalog has no feeds here yet.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    // Suggested gaps only when browsing all topics with empty search
                    if selectedSet == nil && searchText.isEmpty {
                        let gaps = CatalogReviewEngine.detectTopicGaps(subscribedURLs: appSettings.feedURLs)
                        if !gaps.isEmpty {
                            Section {
                                ForEach(gaps) { gap in
                                    gapRow(gap)
                                }
                            } header: {
                                gapsHeader
                            }
                        }
                    }

                    ForEach(displayedSets) { topicSet in
                        let feeds = matchingFeeds(in: topicSet)
                        if !feeds.isEmpty {
                            Section {
                                ForEach(feeds) { feed in
                                    row(feed)
                                }
                            } header: {
                                header(for: topicSet, matchingFeeds: feeds)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        // One width while open: suggested topics recomputing after a subscription never resize the sheet.
        .frame(width: AppLayout.catalogSheetWidth)
        .frame(minHeight: AppLayout.catalogSheetMinHeight)
        .navigationTitle(Self.navigationTitleText)
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .searchable(text: $searchText, prompt: "Search publications, topics, regions…")
        .task { await feedManager.reloadFeedHealth() }
        .onExitCommand { dismiss() }
    }

    private var gapsHeader: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            Text("Suggested Topics & Gaps")
                .font(AppTypography.sectionTitle)
                .tracking(AppTypography.sectionHeaderTracking)
                .foregroundStyle(AppColor.primaryText)
                .accessibilityAddTraits(.isHeader)
            Text("Explore areas not yet covered by your subscriptions.")
                .font(AppTypography.caption)
                .foregroundStyle(AppColor.secondaryText)
        }
        .controlSize(.small)
        .textCase(nil)
        .padding(.vertical, AppSpacing.xs)
    }

    private func gapRow(_ gap: TopicGap) -> some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: "plus.circle")
                .foregroundStyle(AppColor.secondaryText)
                .frame(width: AppSpacing.lg)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(gap.title)
                    .font(AppTypography.body)
                    .foregroundStyle(AppColor.primaryText)
                Text(gap.rationale)
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColor.secondaryText)
            }
            Spacer()
            Button("Subscribe to Set (\(gap.candidateFeeds.count))") {
                feedManager.addCatalogFeeds(gap.candidateFeeds)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Subscribe to \(gap.title), \(gap.candidateFeeds.count) feeds")
        }
        .padding(.vertical, AppSpacing.xxs)
    }

    private func header(for set: CatalogSet, matchingFeeds: [CatalogFeed]) -> some View {
        let remaining = matchingFeeds.filter { !appSettings.isSubscribed($0) }
        return HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(set.title)
                    .font(AppTypography.sectionTitle)
                    .tracking(AppTypography.sectionHeaderTracking)
                    .foregroundStyle(AppColor.primaryText)
                    .accessibilityAddTraits(.isHeader)
                Text(set.summary)
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColor.secondaryText)
            }
            Spacer()
            if remaining.isEmpty {
                Label {
                    Text("Subscribed to all").foregroundStyle(AppColor.primaryText)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(AppColor.success)
                }
                .font(AppTypography.label)
            } else {
                Button(
                    remaining.count == matchingFeeds.count
                        ? "Subscribe to Set (\(matchingFeeds.count))" : "Subscribe to Remaining (\(remaining.count))"
                ) {
                    feedManager.addCatalogFeeds(remaining)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Subscribe to Set, \(remaining.count) feeds in \(set.title)")
            }
        }
        .controlSize(.small)
        .textCase(nil)
        .padding(.vertical, AppSpacing.xs)
    }

    private func row(_ feed: CatalogFeed) -> some View {
        let subscribed = appSettings.isSubscribed(feed)
        return HStack(spacing: AppSpacing.sm) {
            publisherMonogram(feed)
            feedInfoColumn(feed, subscribed: subscribed)
            Spacer()
            feedActionButtons(feed, subscribed: subscribed)
        }
        .padding(.vertical, AppSpacing.xxs)
    }

    private func publisherMonogram(_ feed: CatalogFeed) -> some View {
        Circle()
            .fill(AppColor.accent.opacity(0.12))
            .frame(width: 32, height: 32)
            .overlay(
                Text(String(feed.publisher.prefix(1)))
                    .textCase(.uppercase)
                    .font(AppTypography.headline)
                    .foregroundStyle(AppColor.accent)
            )
            .accessibilityHidden(true)
    }

    private func feedInfoColumn(_ feed: CatalogFeed, subscribed: Bool) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            Text(feed.title)
                .font(AppTypography.body)
                .foregroundStyle(AppColor.primaryText)

            Text(details(feed))
                .font(AppTypography.caption)
                .foregroundStyle(AppColor.secondaryText)

            if subscribed {
                FeedHealthLine(health: feedManager.feedHealth[feed.url])
            }
            if let advisory = appSettings.visibleAdvisory(for: feed.url) {
                Text("Review note (\(advisory.date)): \(advisory.summary)")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColor.primaryText)
            }
            if feed.availability == .previewOnly {
                Text("Story pages may refuse the in-app reader; feed preview still works.")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColor.tertiaryText(for: contrast))
            }
        }
    }

    @ViewBuilder
    private func feedActionButtons(_ feed: CatalogFeed, subscribed: Bool) -> some View {
        if subscribed {
            HStack(spacing: AppSpacing.xs) {
                Label {
                    Text("Subscribed").foregroundStyle(AppColor.primaryText)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(AppColor.success)
                }
                .font(AppTypography.label)

                Button("Remove") { feedManager.removeFeed(url: feed.url) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Remove \(feed.title)")
            }
        } else {
            Button("Subscribe") { feedManager.addCatalogFeeds([feed]) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Subscribe, \(feed.title)")
        }
    }

    private func details(_ feed: CatalogFeed) -> String {
        let locale = Locale.current
        let region =
            feed.region == "global"
            ? "International" : (locale.localizedString(forRegionCode: feed.region) ?? feed.region)
        return [feed.publisher, region, feed.hasImages ? "Images" : nil].compactMap { $0 }.joined(
            separator: " · ")
    }
}
