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
    @Environment(\.colorSchemeContrast) private var contrast

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

            // Category Filter Pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppSpacing.xs) {
                    categoryPill("All Topics", isSelected: selectedSet == nil) {
                        selectedSet = nil
                    }
                    ForEach(CatalogSet.offered) { set in
                        categoryPill(set.title, isSelected: selectedSet == set) {
                            selectedSet = set
                        }
                    }
                }
                .padding(.horizontal, AppLayout.pageInset)
                .padding(.vertical, AppSpacing.xs)
            }

            Divider()

            // Feed Content List
            if allMatchingFeedsCount == 0 && !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
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

                    ForEach(displayedSets) { set in
                        let feeds = matchingFeeds(in: set)
                        if !feeds.isEmpty {
                            Section {
                                ForEach(feeds) { feed in
                                    row(feed)
                                }
                            } header: {
                                header(for: set, matchingCount: feeds.count)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 680, idealWidth: 720, minHeight: 560)
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

    private func categoryPill(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(AppTypography.label)
                .padding(.horizontal, AppSpacing.sm)
                .padding(.vertical, AppSpacing.xxs)
                .background(isSelected ? AppColor.accent : AppColor.surface)
                .foregroundStyle(isSelected ? AppColor.leadText : AppColor.primaryText)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(isSelected ? Color.clear : AppColor.border(for: contrast), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
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
            Image(systemName: "sparkles")
                .foregroundStyle(AppColor.intelligence)
                .frame(width: 20)
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

    private func header(for set: CatalogSet, matchingCount: Int) -> some View {
        let feeds = FeedCatalog.feeds(in: set)
        let remaining = feeds.filter { !appSettings.isSubscribed($0) }
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
                Label("Subscribed to all", systemImage: "checkmark.circle.fill")
                    .font(AppTypography.label)
                    .foregroundStyle(AppColor.success)
            } else {
                Button(
                    remaining.count == feeds.count
                        ? "Subscribe to Set (\(feeds.count))" : "Subscribe to Remaining (\(remaining.count))"
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
            // Publisher Monogram
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

            Spacer()

            if subscribed {
                HStack(spacing: AppSpacing.xs) {
                    Label("Subscribed", systemImage: "checkmark.circle.fill")
                        .font(AppTypography.label)
                        .foregroundStyle(AppColor.success)

                    Button("Remove") { feedManager.removeFeed(url: feed.url) }
                        .buttonStyle(.plain)
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColor.secondaryText)
                        .padding(.horizontal, AppSpacing.xs)
                        .padding(.vertical, AppSpacing.xxs)
                        .background(AppColor.surface)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                                .strokeBorder(AppColor.border(for: contrast), lineWidth: 0.5)
                        )
                        .accessibilityLabel("Remove \(feed.title)")
                }
            } else {
                Button("Subscribe") { feedManager.addCatalogFeeds([feed]) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityLabel("Subscribe, \(feed.title)")
            }
        }
        .padding(.vertical, AppSpacing.xxs)
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
