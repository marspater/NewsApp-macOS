// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "News",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "News", targets: ["News"])
    ],
    targets: [
        .executableTarget(
            name: "News",
            path: ".",
            exclude: [
                "Assets",
                "News.app",
                "News-Universal2.dmg",
                "News-Universal2.zip",
                "News-Universal2.dmg.sha256",
                "News-Universal2.zip.sha256",
                "NewsTests.swift",
                "build.sh",
                "build_release.sh",
                "package_dmg.sh",
                "notarize.sh",
                "test.sh",
                "main",
                "README.md",
                "SECURITY.md",
                "PRIVACY.md",
                "News.entitlements"
            ],
            sources: [
                "AppSettings.swift",
                "ArticleCardView.swift",
                "ArticleDetailView.swift",
                "ArticleIdentity.swift",
                "ArticleIntelligence.swift",
                "ArticleListView.swift",
                "ArticleStore.swift",
                "ArticleWebView.swift",
                "CacheManager.swift",
                "ContentExtractionPipeline.swift",
                "DatabaseEngine.swift",
                "DateParser.swift",
                "DesignSystem.swift",
                "EnrichmentQueue.swift",
                "FeedArticle.swift",
                "FeedError.swift",
                "FeedFetcher.swift",
                "FeedManager.swift",
                "FeedXMLParser.swift",
                "GlassSystem.swift",
                "IPAddressValidator.swift",
                "JSONFeedParser.swift",
                "MainView.swift",
                "MigrationCoordinator.swift",
                "NewsApp.swift",
                "NotificationService.swift",
                "OPMLManager.swift",
                "ReadManager.swift",
                "SavedStoriesManager.swift",
                "SecureHTTPClient.swift",
                "SettingsView.swift",
                "SidebarView.swift",
                "ThemeManager.swift",
                "WebContentExtractor.swift",
                "RefreshCoordinator.swift",
                "NewsSignposts.swift",
                "UpdateChecker.swift",
                "AppContainer.swift"
            ]
        )
    ]
)
