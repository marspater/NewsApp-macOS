import SwiftUI

/// Opt-in browser for the curated starter catalog. Nothing is subscribed until the user chooses it.
struct FeedCatalogView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @EnvironmentObject private var feedManager: FeedManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("Feed Catalog")
                    .font(AppTypography.title)
                    .foregroundColor(AppColor.primaryText)
                    .accessibilityAddTraits(.isHeader)
                Text("Choose a set or single feeds. Nothing is subscribed automatically, and every subscription can be removed in Subscriptions. Details describe how each feed looked when checked on \(FeedCatalog.verifiedOn); they say nothing about the accuracy of a publisher's reporting.")
                    .font(AppTypography.bodySmall)
                    .foregroundColor(AppColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppLayout.pageInset)

            Divider()

            List {
                ForEach(CatalogSet.allCases) { set in
                    Section {
                        ForEach(FeedCatalog.feeds(in: set)) { feed in
                            row(feed)
                        }
                    } header: {
                        header(for: set)
                    }
                }
            }
            .listStyle(.inset)

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(AppSpacing.md)
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 560)
        .task { await feedManager.reloadFeedHealth() }
    }

    private func header(for set: CatalogSet) -> some View {
        let feeds = FeedCatalog.feeds(in: set)
        let remaining = feeds.filter { !appSettings.isSubscribed($0) }
        return HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(set.title)
                    .font(AppTypography.headline)
                    .foregroundColor(AppColor.primaryText)
                    .accessibilityAddTraits(.isHeader)
                Text(set.summary)
                    .font(AppTypography.caption)
                    .foregroundColor(AppColor.secondaryText)
            }
            Spacer()
            if remaining.isEmpty {
                // Bulk removal stays out of the header: a double-click on the swapped button must not unsubscribe a set.
                Label("Subscribed to all", systemImage: "checkmark.circle.fill")
                    .font(AppTypography.label)
                    .foregroundColor(AppColor.success)
            } else {
                Button(remaining.count == feeds.count ? "Subscribe to Set (\(feeds.count))" : "Subscribe to Remaining (\(remaining.count))") {
                    feedManager.addCatalogFeeds(remaining)
                }
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
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(feed.title)
                    .font(AppTypography.body)
                    .foregroundColor(AppColor.primaryText)
                Text(details(feed))
                    .font(AppTypography.caption)
                    .foregroundColor(AppColor.secondaryText)
                if subscribed {
                    FeedHealthLine(health: feedManager.feedHealth[feed.url])
                }
                if feed.availability == .previewOnly {
                    Text("Article pages may refuse the in-app reader; the feed preview still works.")
                        .font(AppTypography.caption)
                        .foregroundColor(AppColor.tertiaryText)
                }
            }
            Spacer()
            if subscribed {
                Label("Subscribed", systemImage: "checkmark.circle.fill")
                    .font(AppTypography.label)
                    .foregroundColor(AppColor.success)
                Button("Remove") { feedManager.removeFeed(url: feed.url) }
                    .controlSize(.small)
                    .accessibilityLabel("Remove \(feed.title)")
            } else {
                Button("Subscribe") { feedManager.addCatalogFeeds([feed]) }
                    .controlSize(.small)
                    .accessibilityLabel("Subscribe, \(feed.title)")
            }
        }
        .padding(.vertical, AppSpacing.xxs)
    }

    private func details(_ feed: CatalogFeed) -> String {
        let locale = Locale.current
        let language = locale.localizedString(forLanguageCode: feed.language) ?? feed.language
        let region = feed.region == "global" ? "International" : (locale.localizedString(forRegionCode: feed.region) ?? feed.region)
        let content: String
        switch feed.fullText {
        case .full: content = "Full text in feed"
        case .partial: content = "Partial text in feed"
        case .summary: content = "Summaries in feed"
        }
        return [feed.publisher, language, region, content, feed.hasImages ? "Images" : nil].compactMap { $0 }.joined(separator: " · ")
    }
}
